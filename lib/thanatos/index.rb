module Thanatos
  class Index
    def initialize
      @facts = {}
    end

    def fetch(fqn, nesting: [])
      @facts[fqn] ||= ClassFacts.new(fqn, nesting:)
    end

    def [](fqn)
      @facts[fqn]
    end

    def all
      @facts.values
    end

    def resolve_inheritance!
      @facts.each_value do |facts|
        facts.superclass_fqn = resolve(facts.superclass_ref, facts.nesting) if facts.superclass_ref
        facts.include_fqns = facts.include_refs.map { |ref| resolve(ref, facts.nesting) }
        facts.extend_fqns = facts.extend_refs.map do |ref|
          ref == :self ? facts.fqn : resolve(ref, facts.nesting)
        end
      end
    end

    # Runtime ancestry spans the superclass chain AND included/prepended
    # modules: either can supply a caller of a method, so reachability follows
    # both, in both directions (ancestors and descendants).
    def ancestors(fqn)
      transitive(fqn) { |name| parents(name) }
    end

    def descendants(fqn)
      transitive(fqn) { |name| children[name] }
    end

    # Classes that `extend` the given module: its instance methods are their
    # class methods, reachable from those classes' singleton context.
    def extenders(fqn)
      extenders_map[fqn]
    end

    def inherits_from?(fqn, base_names)
      bases = base_names.to_set
      ancestor_names(fqn).any? { |name| bases.include?(name) }
    end

    private

    def ancestor_names(fqn)
      [fqn, *ancestors(fqn).map(&:fqn)].each_with_object(Set.new) do |name, names|
        names << name
        facts = @facts[name]
        next unless facts

        names << written(facts.superclass_ref) if facts.superclass_ref
        facts.include_refs.each { |ref| names << written(ref) }
      end
    end

    def parents(fqn)
      facts = @facts[fqn]
      return [] unless facts

      [facts.superclass_fqn, *facts.include_fqns].compact
    end

    def children
      @children ||= Hash.new { |hash, key| hash[key] = [] }.tap do |map|
        @facts.each_key { |fqn| parents(fqn).each { |parent| map[parent] << fqn } }
      end
    end

    def extenders_map
      @extenders_map ||= Hash.new { |hash, key| hash[key] = [] }.tap do |map|
        @facts.each_value { |facts| facts.extend_fqns.each { |target| map[target] << facts } }
      end
    end

    def transitive(fqn)
      collected = Set.new
      queue = yield(fqn).dup

      until queue.empty?
        current = queue.shift
        queue.concat(yield(current)) if collected.add?(current)
      end

      collected.filter_map { |name| @facts[name] }
    end

    def resolve(parts, nesting)
      name = written(parts)
      nesting.reverse_each do |enclosing|
        candidate = "#{enclosing}::#{name}"
        return candidate if @facts.key?(candidate)
      end
      name
    end

    def written(parts)
      parts.map(&:to_s).join("::")
    end
  end
end
