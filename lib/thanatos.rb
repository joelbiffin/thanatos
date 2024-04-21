require 'prism'

class Thanatos
  attr_reader :ast, :method_definitions, :method_calls, :constants

  def initialize(path: 'example/single_class.rb')
    @ast = Prism.parse_file(path)
    @constants = {}
    @method_definitions = []
    @method_calls = []
  end

  def run
    traverse_prism(ast.value)
  end

  def traverse_prism(node, scope: [])
    case node
    when Prism::ClassNode, Prism::ModuleNode
      namespace_scope = scope + [node.name]
      constants[namespace_scope.join("::")] = true
      traverse_children(node, scope: namespace_scope) 
      
      return
    when Prism::DefNode
      method_definitions << node.name
    when Prism::CallNode 
      method_calls << node.name
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
