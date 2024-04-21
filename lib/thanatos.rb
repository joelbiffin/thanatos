require 'prism'

class Thanatos
  attr_reader :ast, :constants

  Methods = Data.define(:definitions, :calls)

  def initialize(path: 'example/single_class.rb')
    @ast = Prism.parse_file(path)
    @constants = {}
    @method_definitions = []
    @method_calls = []
  end

  def run
    traverse_prism(ast.value)
  end

  def method_definitions
    constants.map do |constants, methods|
      methods.definitions
    end.flatten.compact
  end

  def method_calls
    constants.map do |constants, methods|
      methods.calls
    end.flatten.compact
  end

  def traverse_prism(node, scope: [])
    case node
    when Prism::ClassNode, Prism::ModuleNode
      namespace_scope = scope + [node.name]
      constants[namespace_scope.join("::")] = Methods.new(definitions: [], calls: [])
      traverse_children(node, scope: namespace_scope) 
      
      return
    when Prism::DefNode
      @method_definitions << node.name
      constants[scope.join("::")].definitions << node.name
    when Prism::CallNode 
      @method_calls << node.name
      constants[scope.join("::")].calls << node.name
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
