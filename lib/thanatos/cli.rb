require "optparse"

module Thanatos
  class CLI
    CONFIDENCE_RANK = { low: 0, high: 1 }.freeze

    def self.run(argv, out: $stdout)
      new(argv, out:).run
    end

    def initialize(argv, out: $stdout)
      @out = out
      @min_confidence = :low
      @plugin_files = []
      @show_acquittals = false
      @paths = parse(argv)
    end

    def run
      @plugin_files.each { |file| require File.expand_path(file) }
      analyzer = Analyzer.new(paths: @paths, plugins: Thanatos.configuration.plugins)
      candidates = analyzer.call.select { |candidate| meets_min_confidence?(candidate) }
      report(candidates, analyzer.acquittals)
      candidates.any?(&:high_confidence?) ? 1 : 0
    end

    private

    def parse(argv)
      paths = OptionParser.new do |opts|
        opts.on("--min-confidence LEVEL", %w[low high],
                "Only report candidates at this confidence or higher (low|high; default low)") do |level|
          @min_confidence = level.to_sym
        end
        opts.on("--plugins FILE1,FILE2", Array,
                "Ruby files that register plugins via Thanatos.configure") do |files|
          @plugin_files.concat(files)
        end
        opts.on("--show-acquittals", "List the methods plugins acquitted (removed from candidates)") do
          @show_acquittals = true
        end
      end.parse(argv)

      paths.empty? ? ["."] : paths
    end

    def meets_min_confidence?(candidate)
      CONFIDENCE_RANK.fetch(candidate.confidence) >= CONFIDENCE_RANK.fetch(@min_confidence)
    end

    def report(candidates, acquittals)
      if candidates.empty?
        @out.puts "No unused private/protected methods found."
      else
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

      report_acquittals(acquittals) unless acquittals.empty?
    end

    def report_acquittals(acquittals)
      @out.puts ""
      @out.puts "#{acquittals.length} method(s) acquitted by plugins (not flagged; --show-acquittals to review)."
      return unless @show_acquittals

      acquittals.sort_by { |acquittal| [acquittal.fqn, acquittal.name.to_s] }.each do |acquittal|
        @out.puts format("  %-40s %s", "#{acquittal.fqn}##{acquittal.name}", acquittal.sources.join("; "))
        @out.puts "    #{acquittal.location}"
      end
    end
  end
end
