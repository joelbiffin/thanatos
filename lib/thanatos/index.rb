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

    private

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

    def transitive(fqn)
      collected = []
      queue = yield(fqn).dup
      until queue.empty?
        current = queue.shift
        next if collected.include?(current)

        collected << current
        queue.concat(yield(current))
      end
      collected.filter_map { |name| @facts[name] }
    end

    def resolve(parts, nesting)
      written = parts.map(&:to_s).join("::")
      nesting.reverse_each do |enclosing|
        candidate = "#{enclosing}::#{written}"
        return candidate if @facts.key?(candidate)
      end
      written
    end
  end
end
