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
      @paths = parse(argv)
    end

    def run
      candidates = Analyzer.new(paths: @paths, plugins: load_plugins).call
                           .select { |candidate| meets_min_confidence?(candidate) }
      report(candidates)
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
                "Ruby files defining Thanatos::Plugin subclasses to load and apply") do |files|
          @plugin_files.concat(files)
        end
      end.parse(argv)

      paths.empty? ? ["."] : paths
    end

    def load_plugins
      return [] if @plugin_files.empty?

      before = Plugin::REGISTRY.dup
      @plugin_files.each { |file| require File.expand_path(file) }
      (Plugin::REGISTRY - before).map(&:new)
    end

    def meets_min_confidence?(candidate)
      CONFIDENCE_RANK.fetch(candidate.confidence) >= CONFIDENCE_RANK.fetch(@min_confidence)
    end

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
