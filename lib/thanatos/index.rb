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
        next unless facts.superclass_ref

        facts.superclass_fqn = resolve(facts.superclass_ref, facts.nesting)
      end
    end

    def descendants(fqn)
      collected = []
      queue = children[fqn].dup
      until queue.empty?
        current = queue.shift
        next if collected.include?(current)

        collected << current
        queue.concat(children[current])
      end
      collected.filter_map { |descendant| @facts[descendant] }
    end

    def ancestors(fqn)
      collected = []
      current = self[fqn]&.superclass_fqn
      while current && (parent = @facts[current]) && !collected.include?(parent)
        collected << parent
        current = parent.superclass_fqn
      end
      collected
    end

    private

    def children
      @children ||= @facts.each_value.with_object(Hash.new { |hash, key| hash[key] = [] }) do |facts, map|
        map[facts.superclass_fqn] << facts.fqn if facts.superclass_fqn
      end
    end

    def resolve(parts, nesting)
      written = parts.map(&:to_s)
      nesting.length.downto(0) do |depth|
        candidate = (nesting[0...depth] + written).join("::")
        return candidate if @facts.key?(candidate)
      end
      written.join("::")
    end
  end
end
