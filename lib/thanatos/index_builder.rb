module Thanatos
  class IndexBuilder < Prism::Visitor
    VISIBILITY_MODIFIERS = %i[public protected private].freeze

    DYNAMIC_DISPATCH = %i[
      send public_send __send__ define_method define_singleton_method
      method_missing respond_to_missing? method instance_method
      class_eval module_eval instance_eval instance_exec eval
    ].freeze

    # send/public_send/__send__/method(:x) with a *literal* selector resolve to a
    # definite call or reference, so they acquit the target. A computed selector
    # stays in DYNAMIC_DISPATCH above (undecidable -> low-confidence hint).
    RESOLVED_DISPATCH = %i[send public_send __send__ method public_method instance_method].freeze

    # Macros that define methods with literal names. attr_writer/accessor also
    # define the `name=` setter. A computed name is not resolvable here and
    # falls through to the generic path (so a computed define_method stays a
    # dynamic marker).
    ATTR_MACROS = { attr_reader: %i[reader], attr_writer: %i[writer], attr_accessor: %i[reader writer] }.freeze

    # Class.new / Struct.new / Data.define create a NEW anonymous class; a block
    # passed to them is that class's body, not the enclosing class's. We open a
    # fresh scope for it so its defs and visibility do not leak outward.
    ANONYMOUS_CLASS_FACTORIES = { Class: :new, Struct: :new, Data: :define }.freeze

    # include/prepend with a literal module constant puts that module in the
    # includer's ancestry, so the includer's calls can reach the module's
    # methods (and vice versa). A computed argument is undecidable and falls
    # through to the generic path.
    MIXIN_METHODS = %i[include prepend].freeze

    # private_class_method / public_class_method set the visibility of a class
    # method (def self.x); the instance-level private/protected do not.
    CLASS_METHOD_VISIBILITY = { private_class_method: :private, public_class_method: :public }.freeze

    def initialize(index, file:)
      super()
      @index = index
      @file = file
      @scope = []
      @visibility = []
      @facts = []
      @method = []
      @singleton_context = []
    end

    def visit_class_node(node)
      enter(node, superclass: node.superclass)
      visit_child_nodes(node)
      leave
    end

    def visit_module_node(node)
      enter(node, superclass: nil)
      visit_child_nodes(node)
      leave
    end

    # `Const = Class.new(Super)` defines a named class via a factory call, with
    # an optional block body. Name it by the constant and capture its
    # superclass here, rather than letting it fall through as an anonymous
    # class, so the inheritance chain stays linked.
    def visit_constant_write_node(node)
      if class_dot_new?(node.value)
        enter_factory_class(node, node.value)
        visit(node.value.block) if node.value.block.is_a?(Prism::BlockNode)
        leave
        return
      end

      super
    end

    def visit_def_node(node)
      facts = current
      singleton = node.receiver.is_a?(Prism::SelfNode)
      if facts
        if node.receiver.nil?
          facts.add_definition(name: node.name, visibility: @visibility.last, location: location(node))
        elsif singleton
          # `def self.x` is a class method: public unless private_class_method.
          facts.add_singleton_definition(name: node.name, visibility: :public, location: location(node))
        end
      end
      @method << node.name
      @singleton_context << singleton
      visit_child_nodes(node)
      @singleton_context.pop
      @method.pop
    end

    def visit_call_node(node)
      if VISIBILITY_MODIFIERS.include?(node.name) && node.receiver.nil?
        handle_visibility_modifier(node)
        return
      end

      if (visibility = CLASS_METHOD_VISIBILITY[node.name]) && node.receiver.nil?
        handle_class_method_visibility(node, visibility)
        return
      end

      if anonymous_class_block?(node)
        visit_anonymous_class(node)
        return
      end

      facts = current
      return visit_child_nodes(node) unless facts

      if MIXIN_METHODS.include?(node.name) && node.receiver.nil?
        refs = mixin_refs(node)
        unless refs.empty?
          refs.each { |ref| facts.add_include(ref) }
          return
        end
      end

      defined = definition_macro_names(node)
      unless defined.empty?
        handle_definition_macro(node, facts, defined)
        return
      end

      target = resolved_dispatch_target(node)
      if target
        record_call(facts, node.receiver, target)
        visit_dispatch_extras(node)
        return
      end

      record_call(facts, node.receiver, node.name)
      facts.dynamic_markers << node.name if DYNAMIC_DISPATCH.include?(node.name)
      record_alias_method(node, facts)
      visit_child_nodes(node)
    end

    def visit_symbol_node(node)
      current&.symbol_literals&.add(node.unescaped.to_sym)
      super
    end

    def visit_alias_method_node(node)
      facts = current
      if facts && node.old_name.is_a?(Prism::SymbolNode)
        record_self_call(facts, node.old_name.unescaped.to_sym)
      end
      super
    end

    # `&:foo` calls foo on each element, not on self, so it is not a usage hint
    # for self's methods. Skip the symbol; visit other block expressions (e.g.
    # `&method(:foo)`, which does reference foo) normally.
    def visit_block_argument_node(node)
      return if node.expression.is_a?(Prism::SymbolNode)

      super
    end

    # Fold an `if` with a literal true/false/nil predicate: only the taken
    # branch can run, so only it is visited. This keeps a guarded modifier
    # (`private if false`) or a dead `def` from taking effect. A non-literal
    # (runtime) predicate is visited normally.
    def visit_if_node(node)
      case literal_branch(node.predicate)
      when :then then visit(node.statements) if node.statements
      when :else then visit(node.subsequent) if node.subsequent
      else super
      end
    end

    private

    def enter(node, superclass:)
      own = constant_parts(node.constant_path).map(&:to_s).join("::")
      fqn =
        if absolute_constant_path?(node.constant_path) || @scope.empty?
          own
        else
          "#{@scope.last}::#{own}"
        end
      facts = @index.fetch(fqn, nesting: @scope.dup)

      reference = constant_parts(superclass)
      facts.superclass_ref = reference unless reference.empty?

      push_scope(fqn, facts)
    end

    def leave
      @facts.pop
      @visibility.pop
      @scope.pop
      @method.pop
      @singleton_context.pop
    end

    def push_scope(fqn, facts)
      @scope << fqn
      @visibility << :public
      @facts << facts
      @method << nil
      @singleton_context << false
    end

    def class_dot_new?(node)
      node.is_a?(Prism::CallNode) &&
        node.receiver.is_a?(Prism::ConstantReadNode) &&
        node.receiver.name == :Class && node.name == :new
    end

    def enter_factory_class(write_node, call_node)
      own = write_node.name.to_s
      fqn = @scope.empty? ? own : "#{@scope.last}::#{own}"
      facts = @index.fetch(fqn, nesting: @scope.dup)

      reference = constant_parts((call_node.arguments&.arguments || []).first)
      facts.superclass_ref = reference unless reference.empty?

      push_scope(fqn, facts)
    end

    def current
      @facts.last
    end

    def literal_branch(predicate)
      case predicate
      when Prism::TrueNode then :then
      when Prism::FalseNode, Prism::NilNode then :else
      end
    end

    def anonymous_class_block?(node)
      node.block.is_a?(Prism::BlockNode) &&
        node.receiver.is_a?(Prism::ConstantReadNode) &&
        ANONYMOUS_CLASS_FACTORIES[node.receiver.name] == node.name
    end

    def visit_anonymous_class(node)
      fqn = "(anonymous):#{location(node)}"
      push_scope(fqn, @index.fetch(fqn, nesting: @scope.dup))
      visit(node.block)
      leave
    end

    def handle_visibility_modifier(node)
      facts = current
      arguments = node.arguments&.arguments || []

      if arguments.empty?
        @visibility[-1] = node.name if facts
        return
      end

      arguments.each do |argument|
        case argument
        when Prism::SymbolNode, Prism::StringNode
          facts&.mark_visibility(argument.unescaped.to_sym, node.name)
        when Prism::DefNode
          facts&.mark_visibility(argument.name, node.name)
          visit_def_node(argument)
        else
          visit(argument)
        end
      end
    end

    def handle_class_method_visibility(node, visibility)
      facts = current
      (node.arguments&.arguments || []).each do |argument|
        case argument
        when Prism::SymbolNode, Prism::StringNode
          facts&.mark_singleton_visibility(argument.unescaped.to_sym, visibility)
        when Prism::DefNode
          facts&.mark_singleton_visibility(argument.name, visibility)
          visit_def_node(argument)
        else
          visit(argument)
        end
      end
    end

    def record_alias_method(node, facts)
      return unless node.name == :alias_method

      original = (node.arguments&.arguments || [])[1]
      return unless original.is_a?(Prism::SymbolNode) || original.is_a?(Prism::StringNode)

      record_self_call(facts, original.unescaped.to_sym)
    end

    def record_call(facts, receiver, name)
      if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        record_self_call(facts, name)
      else
        facts.explicit_calls << name
      end
    end

    # An implicit/self call lands in the instance graph by default, but in the
    # body of a `def self.x` (or another class-method context) it is a class-
    # method call, so it lands in the singleton graph.
    def record_self_call(facts, callee)
      caller = @method.last || ClassFacts::CLASS_BODY
      if @singleton_context.last
        facts.add_singleton_call(caller, callee)
      else
        facts.add_call(caller, callee)
      end
    end

    def resolved_dispatch_target(node)
      return nil unless RESOLVED_DISPATCH.include?(node.name)

      selector = node.arguments&.arguments&.first
      return nil unless selector.is_a?(Prism::SymbolNode) || selector.is_a?(Prism::StringNode)

      selector.unescaped.to_sym
    end

    def visit_dispatch_extras(node)
      visit(node.receiver) if node.receiver
      (node.arguments&.arguments || [])[1..].each { |argument| visit(argument) }
      visit(node.block) if node.block
    end

    def definition_macro_names(node)
      return [] unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

      if node.name == :define_method
        selector = (node.arguments&.arguments || []).first
        return [] unless selector.is_a?(Prism::SymbolNode) || selector.is_a?(Prism::StringNode)

        [selector.unescaped.to_sym]
      elsif (kinds = ATTR_MACROS[node.name])
        literal_symbol_arguments(node).flat_map do |base|
          names = []
          names << base if kinds.include?(:reader)
          names << :"#{base}=" if kinds.include?(:writer)
          names
        end
      else
        []
      end
    end

    def handle_definition_macro(node, facts, names)
      names.each do |name|
        facts.add_definition(name: name, visibility: @visibility.last, location: location(node))
      end

      body_method = names.first if node.name == :define_method
      if body_method
        @method << body_method
        @singleton_context << false
      end
      visit(node.block) if node.block
      if body_method
        @singleton_context.pop
        @method.pop
      end

      (node.arguments&.arguments || []).each do |argument|
        visit(argument) unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
    end

    def literal_symbol_arguments(node)
      (node.arguments&.arguments || []).filter_map do |argument|
        argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
    end

    def mixin_refs(node)
      (node.arguments&.arguments || []).filter_map do |argument|
        parts = constant_parts(argument)
        parts unless parts.empty?
      end
    end

    def constant_parts(node)
      case node
      when Prism::ConstantReadNode then [node.name]
      when Prism::ConstantPathNode then constant_parts(node.parent) + [node.name]
      else []
      end
    end

    # `::Foo` / `::A::Foo` is rooted at the top level: the chain's leftmost
    # element is a ConstantPathNode with no parent. A relative name bottoms out
    # at a ConstantReadNode instead.
    def absolute_constant_path?(node)
      node.is_a?(Prism::ConstantPathNode) && (node.parent.nil? || absolute_constant_path?(node.parent))
    end

    def location(node)
      "#{@file}:#{node.location.start_line}"
    end
  end
end
