module Thanatos
  class IndexBuilder < Prism::Visitor
    VISIBILITY_MODIFIERS = %i[public protected private].freeze

    DYNAMIC_DISPATCH = %i[
      send public_send __send__ define_method define_singleton_method
      method_missing respond_to_missing? method instance_method
      class_eval module_eval instance_eval instance_exec eval
    ].freeze

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
      if facts
        if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          facts.implicit_calls << node.name
        else
          facts.explicit_calls << node.name
        end
        facts.dynamic_markers << node.name if DYNAMIC_DISPATCH.include?(node.name)
        record_alias_method(node, facts)
      end

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
