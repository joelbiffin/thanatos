require 'parser'
require 'prism'

class Thanatos
  class << self 
    def run
      self.new
    end
  end

  attr_reader :ast, :method_definitions, :method_calls, :constants

  def initialize(path: 'example/single_class.rb')
    @ast = Prism::Translation::Parser.parse_file(path)
    @constants = {}
    @method_definitions = []
    @method_calls = []
  end

  def run
    traverse_and_track_tree(ast)
  end

  def traverse_and_track_tree(node, scope: [])
    case node.type
    when :class, :module
      namespace_scope = scope + [node.children.first.children.last]
      traverse_node_children(node, scope: namespace_scope)

      return
    when :const
      const_name = scope.join("::")
      constants[const_name] = true
    when :send
      method_calls << node.children[1] if node.children[1]
    when :def
      method_definitions << node.children[0]
    end 

    traverse_node_children(node, scope:)
  end

  def traverse_node_children(node, scope:)
    node.children.each do |child_node|
      next unless child_node.is_a?(Parser::AST::Node)

      traverse_and_track_tree(child_node, scope:)
    end
  end
end

