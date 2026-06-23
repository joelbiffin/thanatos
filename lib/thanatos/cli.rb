module Thanatos
  class CLI
    def self.run(argv, out: $stdout)
      new(argv, out:).run
    end

    def initialize(argv, out: $stdout)
      @paths = argv.empty? ? ["."] : argv
      @out = out
    end

    def run
      candidates = Analyzer.new(paths: @paths).call
      report(candidates)
      candidates.any?(&:high_confidence?) ? 1 : 0
    end

    private

    def report(candidates)
      if candidates.empty?
        @out.puts "No unused private/protected methods found."
        return
      end

      candidates.group_by(&:fqn).sort_by(&:first).each do |fqn, group|
        @out.puts fqn
        group.each do |candidate|
          @out.puts format(
            "  %-9s %-28s %-5s %s",
            candidate.visibility, candidate.name, candidate.confidence, candidate.location
          )
          candidate.reasons.each { |reason| @out.puts "    ↳ #{reason}" }
        end
      end

      high = candidates.count(&:high_confidence?)
      @out.puts ""
      @out.puts "#{candidates.length} candidate(s), #{high} high-confidence."
    end
  end
end
