require 'prism'

class Thanatos
  attr_reader :ast, :constants

  Methods = Data.define(:definitions, :calls)

  class Constants < Hash
    def find_or_initialize(scope:, node:)
      if node.superclass
        superclass = node.superclass.name.to_s
        hash = self[superclass]
        debugger
      end
      self[scope.join("::")] ||= Methods.new(
        definitions: {
          private: [],
          public: [],
          protected: []
        },
        calls: []
      )
    end

    def add_definition(node, scope:, visibility: :public)
      self[scope.join("::")].definitions[visibility] << node.name
    end

    def add_call(node, scope:)
      self[scope.join("::")].calls << node.name
    end

    def definitions(visibility)
      each_with_object({}) { |(klass, methods), hash| hash[klass] = methods.definitions[visibility] }
    end

    def calls
      each_with_object({}) { |(klass, methods), hash| hash[klass] = methods.calls }
    end
  end

  VISIBILITY_MODIFIERS = [:public, :protected, :private].freeze

  def initialize(path: 'example/single_class.rb')
    @ast = Prism.parse_file(path)
    @constants = Constants.new
    @visibility = :public
  end

  def run
    traverse_prism(ast.value)
  end

  def method_definitions(visibility)
    constants.definitions(visibility)
  end

  def unused_private_methods
    method_definitions(:private).each_with_object({}) do |(key, value), hash|
      hash[key] = value - method_calls[key]
    end
  end

  def method_calls
    constants.calls
  end

  def traverse_prism(node, scope: [])
    case node
    when Prism::ClassNode, Prism::ModuleNode
      @visibility = :public
      namespace_scope = scope + [node.name]
      constants.find_or_initialize(scope: namespace_scope, node: node)
      traverse_children(node, scope: namespace_scope)

      return
    when Prism::DefNode
      constants.add_definition(node, scope:, visibility: @visibility)
    when Prism::CallNode
      if VISIBILITY_MODIFIERS.include?(node.name)
        @visibility = node.name
      else
        constants.add_call(node, scope:)
      end
    end

    traverse_children(node, scope:)
  end

  def traverse_children(parent_node, scope:)
    parent_node.child_nodes.each do |child_node|
      next unless child_node.is_a?(Prism::Node)

      traverse_prism(child_node, scope:)
    end
  end
end
