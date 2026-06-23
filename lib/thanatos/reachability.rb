module Thanatos
  class Reachability
    NON_PUBLIC = %i[private protected].freeze

    def initialize(index)
      @index = index
    end

    def candidates
      @index.resolve_inheritance!
      global_explicit_calls = @index.all.flat_map { |facts| facts.explicit_calls.to_a }.to_set

      @index.all.flat_map do |facts|
        hierarchy = [facts, *@index.ancestors(facts.fqn), *@index.descendants(facts.fqn)]
        called = union(hierarchy, :implicit_calls)
        symbols = union(hierarchy, :symbol_literals)
        markers = union(hierarchy, :dynamic_markers)

        facts.definitions.filter_map do |definition|
          next unless NON_PUBLIC.include?(definition.visibility)
          next if called.include?(definition.name)

          reasons = reasons_for(definition, symbols:, markers:, global_explicit_calls:)
          Candidate.new(
            fqn: facts.fqn,
            name: definition.name,
            visibility: definition.visibility,
            location: definition.location,
            confidence: reasons.empty? ? :high : :low,
            reasons:
          )
        end
      end
    end

    private

    def reasons_for(definition, symbols:, markers:, global_explicit_calls:)
      reasons = []

      if symbols.include?(definition.name)
        reasons << "referenced as symbol literal :#{definition.name} (callback/delegate/send?)"
      end

      if markers.any?
        reasons << "class uses dynamic dispatch (#{markers.sort.join(', ')})"
      end

      if definition.visibility == :protected && global_explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} found elsewhere (possible protected use)"
      end

      reasons
    end

    def union(hierarchy, attribute)
      hierarchy.flat_map { |facts| facts.public_send(attribute).to_a }.to_set
    end
  end
end
