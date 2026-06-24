module Thanatos
  class ClassFacts
    attr_reader :fqn, :nesting, :implicit_calls, :explicit_calls,
                :symbol_literals, :dynamic_markers
    attr_accessor :superclass_ref, :superclass_fqn

    def initialize(fqn, nesting: [])
      @fqn = fqn
      @nesting = nesting
      @superclass_ref = nil
      @superclass_fqn = nil
      @definitions = []
      @visibility_marks = {}
      @implicit_calls = Set.new
      @explicit_calls = Set.new
      @symbol_literals = Set.new
      @dynamic_markers = Set.new
    end

    def add_definition(name:, visibility:, location:)
      @definitions << MethodDefinition.new(name:, visibility:, location:)
    end

    def mark_visibility(name, visibility)
      @visibility_marks[name] = visibility
    end

    def definitions
      @definitions.map do |definition|
        marked = @visibility_marks[definition.name]
        next definition unless marked

        MethodDefinition.new(
          name: definition.name,
          visibility: marked,
          location: definition.location
        )
      end.reverse.uniq(&:name).reverse
    end
  end
end
