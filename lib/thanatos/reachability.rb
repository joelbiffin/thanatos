module Thanatos
  class Reachability
    NON_PUBLIC = %i[private protected].freeze

    def initialize(index)
      @index = index
    end

    def candidates
      @index.resolve_inheritance!

      @index.all.flat_map do |facts|
        hierarchy = [facts, *@index.ancestors(facts.fqn), *@index.descendants(facts.fqn)]
        symbols = union(hierarchy, :symbol_literals)
        markers = union(hierarchy, :dynamic_markers)
        explicit = union(hierarchy, :explicit_calls)

        %i[instance singleton].flat_map do |dimension|
          reachable = reachable_methods(contributions(facts, dimension))

          definitions_for(facts, dimension).filter_map do |definition|
            next unless NON_PUBLIC.include?(definition.visibility)
            next if reachable.include?(definition.name)

            reasons = reasons_for(definition, symbols:, markers:, explicit_calls: explicit)
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
    end

    private

    # Instance methods and class (singleton) methods are separate method tables,
    # so reachability runs once per dimension.
    def definitions_for(facts, dimension)
      dimension == :singleton ? facts.singleton_definitions : facts.definitions
    end

    def edges_for(facts, dimension)
      dimension == :singleton ? facts.singleton_call_edges : facts.call_edges
    end

    # The (facts, dimension) pairs whose methods share `facts`'s method table for
    # this dimension. Same dimension: the class plus its ancestors and
    # descendants. Cross dimension (extend): a class's singleton table also draws
    # on the instance methods of every module it extends, and a module's instance
    # methods are reachable from the singleton context of every class extending it.
    def contributions(facts, dimension)
      same = [facts, *@index.ancestors(facts.fqn), *@index.descendants(facts.fqn)]
      result = same.map { |f| [f, dimension] }

      if dimension == :singleton
        same.each do |f|
          f.extend_fqns.each do |target|
            extended = @index[target]
            next unless extended

            [extended, *@index.ancestors(target)].each { |e| result << [e, :instance] }
          end
        end
      else
        @index.extenders(facts.fqn).each do |extender|
          [extender, *@index.ancestors(extender.fqn)].each { |e| result << [e, :singleton] }
        end
      end

      result.uniq
    end

    # A non-public method is dead unless a LIVE method reaches it. The roots are
    # the class body (it runs on load) and every public method (callable from
    # outside); from there we follow call edges. This is reachability from
    # roots, not "has any caller", so dead clusters and recursion no longer hide
    # behind each other.
    # `scope` is a list of [facts, dimension] pairs whose methods share one
    # resolution table; we merge their call edges and public methods into one
    # name-based graph and reach out from the roots.
    def reachable_methods(scope)
      graph = Hash.new { |edges, caller| edges[caller] = Set.new }
      roots = Set[ClassFacts::CLASS_BODY]

      scope.each do |facts, dimension|
        edges_for(facts, dimension).each { |caller, callees| graph[caller].merge(callees) }
        definitions_for(facts, dimension).each { |definition| roots << definition.name if definition.visibility == :public }
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

    def reasons_for(definition, symbols:, markers:, explicit_calls:)
      reasons = []

      if symbols.include?(definition.name)
        reasons << "referenced as symbol literal :#{definition.name} (callback/delegate/send?)"
      end

      if markers.any?
        reasons << "class uses dynamic dispatch (#{markers.sort.join(', ')})"
      end

      if definition.visibility == :protected && explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} in the hierarchy (possible protected use)"
      end

      reasons
    end

    def union(hierarchy, attribute)
      hierarchy.flat_map { |facts| facts.public_send(attribute).to_a }.to_set
    end
  end
end
