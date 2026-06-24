module Thanatos
  class ClassFacts
    # Calls made at class-body level (outside any method) run on load, so they
    # seed reachability like a root.
    CLASS_BODY = :"(class body)"

    attr_reader :fqn, :nesting, :call_edges, :singleton_call_edges, :explicit_calls,
                :symbol_literals, :dynamic_markers, :include_refs
    attr_accessor :superclass_ref, :superclass_fqn, :include_fqns

    def initialize(fqn, nesting: [])
      @fqn = fqn
      @nesting = nesting
      @superclass_ref = nil
      @superclass_fqn = nil
      @include_refs = []
      @include_fqns = []
      @definitions = []
      @singleton_definitions = []
      @visibility_marks = {}
      @singleton_visibility_marks = {}
      @call_edges = Hash.new { |edges, caller| edges[caller] = Set.new }
      @singleton_call_edges = Hash.new { |edges, caller| edges[caller] = Set.new }
      @explicit_calls = Set.new
      @symbol_literals = Set.new
      @dynamic_markers = Set.new
    end

    def add_definition(name:, visibility:, location:)
      @definitions << MethodDefinition.new(name:, visibility:, location:)
    end

    def add_singleton_definition(name:, visibility:, location:)
      @singleton_definitions << MethodDefinition.new(name:, visibility:, location:)
    end

    def add_call(caller, callee)
      @call_edges[caller] << callee
    end

    def add_singleton_call(caller, callee)
      @singleton_call_edges[caller] << callee
    end

    def add_include(ref)
      @include_refs << ref
    end

    def mark_visibility(name, visibility)
      @visibility_marks[name] = visibility
    end

    def mark_singleton_visibility(name, visibility)
      @singleton_visibility_marks[name] = visibility
    end

    # Every method called (implicitly / via self) anywhere in the class,
    # regardless of which method made the call. Derived from the call graph.
    def implicit_calls
      @call_edges.each_value.reduce(Set.new, :|)
    end

    def definitions
      resolved(@definitions, @visibility_marks)
    end

    def singleton_definitions
      resolved(@singleton_definitions, @singleton_visibility_marks)
    end

    private

    def resolved(definitions, marks)
      definitions.map do |definition|
        marked = marks[definition.name]
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
