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
      compute
      @candidates
    end

    def acquittals
      compute
      @acquittals
    end

    private

    def compute
      return if @computed

      @index.resolve_inheritance!
      apply_plugins!
      @candidates = []
      @acquittals = []

      @index.all.each do |facts|
        hierarchy = [facts, *@index.ancestors(facts.fqn), *@index.descendants(facts.fqn)]
        signals = merged_signals(hierarchy)
        explicit = union(hierarchy, :explicit_calls)
        plugin_reasons = union_plugin_reasons(hierarchy)

        %i[instance singleton].each do |dimension|
          scope = contributions(facts, dimension)
          acquitted = acquitted_in(scope)
          reached_real = reachable_methods(scope)
          reached = acquitted.empty? ? reached_real : reachable_methods(scope, acquitted.keys)

          definitions_for(facts, dimension).each do |definition|
            next unless NON_PUBLIC.include?(definition.visibility)

            name = definition.name
            if reached.include?(name)
              next unless acquitted.key?(name) && !reached_real.include?(name)

              @acquittals << Acquittal.new(fqn: facts.fqn, name:, location: definition.location, sources: acquitted[name].uniq)
              next
            end

            confidence, reasons = grade(definition, signals:, hierarchy:, explicit_calls: explicit, plugin_reasons:)
            @candidates << Candidate.new(
              fqn: facts.fqn,
              name:,
              visibility: definition.visibility,
              location: definition.location,
              confidence:,
              reasons:
            )
          end
        end
      end

      @computed = true
    end

    def apply_plugins!
      return if @plugins.empty?

      @index.all.each do |facts|
        @plugins.each do |plugin|
          next unless plugin.applies_to?(@index, facts.fqn)

          plugin.reasons_for_class(facts).each { |name, reason| facts.plugin_reasons[name] << reason }
          plugin.invocations_for_class(facts).each { |name, macro| facts.acquittals[name] << "#{plugin_label(plugin)} via #{macro}" }
          if (reach = plugin.account_for(facts))
            facts.dispatch_accounts << DispatchAccount.new(reach: Reach.new(reach), source: plugin_label(plugin))
          end
        end
      end
    end

    def plugin_label(plugin)
      plugin.class.name || plugin.class.to_s
    end

    def acquitted_in(scope)
      scope.map(&:first).uniq.each_with_object(Hash.new { |sources, name| sources[name] = [] }) do |facts, merged|
        facts.acquittals.each { |name, sources| merged[name].concat(sources.to_a) }
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
    def reachable_methods(scope, extra_roots = [])
      graph = Hash.new { |edges, caller| edges[caller] = Set.new }
      roots = Set[ClassFacts::CLASS_BODY, *RUNTIME_HOOKS, *extra_roots]

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

    def grade(definition, signals:, hierarchy:, explicit_calls:, plugin_reasons:)
      reasons = signals.reasons_for(definition)

      verdict, accounted_note = markers_verdict(hierarchy, definition)
      reasons << signals.dynamic_dispatch_reason if verdict == :tainted

      if definition.visibility == :protected && explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} in the hierarchy (possible protected use)"
      end
      reasons.concat(plugin_reasons[definition.name])

      confidence =
        if reasons.any?
          :low
        elsif verdict == :accounted_clean
          :medium
        else
          :high
        end
      reasons << accounted_note if confidence == :medium
      [confidence, reasons]
    end

    # A marker taints a candidate unless every marker-bearing class in its hierarchy
    # is accounted for by a plugin whose reach excludes this method. All accounted
    # and none reaching -> :accounted_clean (with the provenance note for :medium).
    def markers_verdict(hierarchy, definition)
      marker_classes = hierarchy.select { |facts| facts.signals.dynamic_markers.any? }
      return [:none, nil] if marker_classes.empty?

      sources = []
      marker_classes.each do |marker_class|
        accounts = marker_class.dispatch_accounts
        return [:tainted, nil] if accounts.empty?
        return [:tainted, nil] if accounts.any? { |account| account.reaches?(definition.name) }

        sources.concat(accounts.map { |account| "#{account.source} (dispatch in #{marker_class.fqn})" })
      end
      [:accounted_clean, "dispatch accounted for by #{sources.uniq.join(', ')}"]
    end

    def union(hierarchy, attribute)
      hierarchy.flat_map { |facts| facts.public_send(attribute).to_a }.to_set
    end
  end
end
