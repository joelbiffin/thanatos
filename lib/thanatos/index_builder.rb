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

    def initialize(index, file:)
      super()
      @index = index
      @file = file
      @scope = []
      @visibility = []
      @facts = []
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

    def visit_def_node(node)
      facts = current
      if facts && node.receiver.nil?
        facts.add_definition(name: node.name, visibility: @visibility.last, location: location(node))
      end
      visit_child_nodes(node)
    end

    def visit_call_node(node)
      if VISIBILITY_MODIFIERS.include?(node.name) && node.receiver.nil?
        handle_visibility_modifier(node)
        return
      end

      facts = current
      return visit_child_nodes(node) unless facts

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
        facts.implicit_calls << node.old_name.unescaped.to_sym
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

    private

    def enter(node, superclass:)
      parts = constant_parts(node.constant_path).map(&:to_s)
      fqn = (@scope + [parts.join("::")]).join("::")
      facts = @index.fetch(fqn, nesting: @scope.dup)

      reference = constant_parts(superclass)
      facts.superclass_ref = reference unless reference.empty?

      @scope << parts.join("::")
      @visibility << :public
      @facts << facts
    end

    def leave
      @facts.pop
      @visibility.pop
      @scope.pop
    end

    def current
      @facts.last
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

    def record_alias_method(node, facts)
      return unless node.name == :alias_method

      original = (node.arguments&.arguments || [])[1]
      return unless original.is_a?(Prism::SymbolNode) || original.is_a?(Prism::StringNode)

      facts.implicit_calls << original.unescaped.to_sym
    end

    def record_call(facts, receiver, name)
      if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        facts.implicit_calls << name
      else
        facts.explicit_calls << name
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

      visit(node.block) if node.block
      (node.arguments&.arguments || []).each do |argument|
        visit(argument) unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
    end

    def literal_symbol_arguments(node)
      (node.arguments&.arguments || []).filter_map do |argument|
        argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
    end

    def constant_parts(node)
      case node
      when Prism::ConstantReadNode then [node.name]
      when Prism::ConstantPathNode then constant_parts(node.parent) + [node.name]
      else []
      end
    end

    def location(node)
      "#{@file}:#{node.location.start_line}"
    end
  end
end
