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
        reachable = reachable_methods(hierarchy)
        symbols = union(hierarchy, :symbol_literals)
        markers = union(hierarchy, :dynamic_markers)

        facts.definitions.filter_map do |definition|
          next unless NON_PUBLIC.include?(definition.visibility)
          next if reachable.include?(definition.name)

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

    # A non-public method is dead unless a LIVE method reaches it. The roots are
    # the class body (it runs on load) and every public method (callable from
    # outside); from there we follow call edges. This is reachability from
    # roots, not "has any caller", so dead clusters and recursion no longer hide
    # behind each other.
    def reachable_methods(hierarchy)
      graph = Hash.new { |edges, caller| edges[caller] = Set.new }
      roots = Set[ClassFacts::CLASS_BODY]

      hierarchy.each do |facts|
        facts.call_edges.each { |caller, callees| graph[caller].merge(callees) }
        facts.definitions.each { |definition| roots << definition.name if definition.visibility == :public }
      end

      reached = Set.new
      queue = roots.to_a
      until queue.empty?
        method = queue.shift
        next if reached.include?(method)

        reached << method
        graph[method].each { |callee| queue << callee unless reached.include?(callee) }
      end
      reached
    end

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
