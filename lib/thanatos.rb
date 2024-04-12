require 'parser'
require 'prism'

require_relative '../example/foo.rb'

class Thanatos
  class << self 
    def run
      self.new
    end
  end

  attr_reader :ast, :method_definitions, :method_calls

  def initialize(path: 'example/foo.rb')
    @ast = Prism::Translation::Parser.parse_file(path)
    @method_definitions = []
    @method_calls = []
  end

  def run
    traverse_and_track_tree(ast)
  end

  def traverse_and_track_tree(node)
    case node.type
    when :send
      method_calls << node.children[1] if node.children[1]
    when :def
      method_definitions << node.children[0]
    end

    node.children.each do |child_node|
      next unless child_node.is_a?(Parser::AST::Node)

      traverse_and_track_tree(child_node)
    end
  end
end
