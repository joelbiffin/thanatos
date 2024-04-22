require 'prism'

class Thanatos
  attr_reader :ast, :constants

  Methods = Data.define(:definitions, :calls)
  Definition = Data.define(:name, :type) do
    def instance?
      type == :instance
    end

    def class?
      type == :class
    end
  end 

  class Constants < Hash
    def find_or_initialize(scope:)
      self[scope.join("::")] ||= Methods.new(definitions: [], calls: [])
    end 

    def add_definition(node, scope:)
      find_or_initialize(scope:).definitions << Definition.new(
        name: node.name,
        type: node.receiver == :self ? :class : :instance,
      )
    end

    def add_call(node, scope:)
      find_or_initialize(scope:).calls << node.name
    end 

    def definitions
      map { |_, methods| methods.definitions }.flatten.compact
    end

    def calls
      map { |_, methods| methods.calls }.flatten.compact
    end
  end

  def initialize(path: 'example/single_class.rb')
    @ast = Prism.parse_file(path)
    @constants = Constants.new 
  end

  def run
    traverse_prism(ast.value)
  end

  def method_definitions
    constants.definitions.map(&:name)
  end

  def instance_method_definitions
    constants.defintions.filter(&:instance?).map(&:name)
  end

  def class_method_definitions
    constants.definitions.filter(&:class?).map(&:name)
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
      constants.add_definition(node, scope:)
    when Prism::CallNode 
      constants.add_call(node, scope:)
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
