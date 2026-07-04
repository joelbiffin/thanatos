module Thanatos
  class Reachability
    NON_PUBLIC = %i[private protected].freeze

    # Methods the Ruby runtime invokes directly - the constructor and the
    # reflection / lifecycle hooks - never via an explicit call. A defined hook
    # is reachable, so it seeds reachability like a root (in either dimension).
    RUNTIME_HOOKS = %i[
      initialize initialize_copy initialize_clone initialize_dup
      method_missing respond_to_missing?
      method_added method_removed singleton_method_added
      inherited included extended prepended
      const_missing coerce
    ].freeze

    def initialize(index, plugins: [])
      @index = index
      @plugins = plugins
    end

    def candidates
      @index.resolve_inheritance!
      apply_plugins!

      @index.all.flat_map do |facts|
        hierarchy = [facts, *@index.ancestors(facts.fqn), *@index.descendants(facts.fqn)]
        signals = merged_signals(hierarchy)
        explicit = union(hierarchy, :explicit_calls)
        plugin_reasons = union_plugin_reasons(hierarchy)

        %i[instance singleton].flat_map do |dimension|
          reachable = reachable_methods(contributions(facts, dimension))

          definitions_for(facts, dimension).filter_map do |definition|
            next unless NON_PUBLIC.include?(definition.visibility)
            next if reachable.include?(definition.name)

            reasons = reasons_for(definition, signals:, explicit_calls: explicit, plugin_reasons:)
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

    def apply_plugins!
      return if @plugins.empty?

      @index.all.each do |facts|
        @plugins.each do |plugin|
          next unless plugin.applies_to?(@index, facts.fqn)

          plugin.reasons_for_class(facts).each { |name, reason| facts.plugin_reasons[name] << reason }
        end
      end
    end

    def merged_signals(hierarchy)
      hierarchy.each_with_object(ReferenceSignals.new) { |facts, merged| merged.merge(facts.signals) }
    end

    def union_plugin_reasons(hierarchy)
      hierarchy.each_with_object(Hash.new { |reasons, name| reasons[name] = [] }) do |facts, merged|
        facts.plugin_reasons.each { |name, reasons| merged[name].concat(reasons.to_a) }
      end
    end

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
      roots = Set[ClassFacts::CLASS_BODY, *RUNTIME_HOOKS]

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

    def reasons_for(definition, signals:, explicit_calls:, plugin_reasons:)
      reasons = signals.reasons_for(definition)

      if definition.visibility == :protected && explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} in the hierarchy (possible protected use)"
      end

      reasons.concat(plugin_reasons[definition.name])
      reasons
    end

    def union(hierarchy, attribute)
      hierarchy.flat_map { |facts| facts.public_send(attribute).to_a }.to_set
    end
  end
end
