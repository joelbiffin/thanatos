require 'prism'

class Thanatos
  attr_reader :ast, :constants

  Methods = Data.define(:definitions, :calls)

  class Constants < Hash
    def find_or_initialize(scope:)
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
      find_or_initialize(scope:).definitions[visibility] << node.name
    end

    def add_call(node, scope:)
      find_or_initialize(scope:).calls << node.name
    end

    def definitions(visibility)
      map { |_, methods| methods.definitions[visibility] }.flatten.compact
    end

    def calls
      map { |_, methods| methods.calls }.flatten.compact
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

  def method_calls
    constants.calls
  end

  def traverse_prism(node, scope: [])
    case node
    when Prism::ClassNode, Prism::ModuleNode
      namespace_scope = scope + [node.name]
      constants.find_or_initialize(scope: namespace_scope)
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
