module Thanatos
  class Analyzer
    attr_reader :paths

    def initialize(paths:)
      @paths = Array(paths).flat_map { |path| expand(path) }.uniq
    end

    def call
      index = Index.new
      @paths.each do |path|
        result = Prism.parse_file(path)
        IndexBuilder.new(index, file: path).visit(result.value)
      end
      Reachability.new(index).candidates
    end

    private

    def expand(path)
      if File.directory?(path)
        Dir.glob(File.join(path, "**", "*.rb")).sort
      else
        [path]
      end
    end
  end
end
