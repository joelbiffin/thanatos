module Thanatos
  class Analyzer
    attr_reader :paths, :parse_errors, :acquittals

    def initialize(paths:, plugins: [])
      @paths = Array(paths).flat_map { |path| expand(path) }.uniq
      @parse_errors = []
      @plugins = plugins
      @acquittals = []
    end

    def call
      index = Index.new
      locals = []
      @paths.each do |path|
        result = Prism.parse_file(path)
        result.errors.each do |error|
          @parse_errors << "#{path}:#{error.location.start_line}: #{error.message}"
        end
        IndexBuilder.new(index, file: path).visit(result.value)
        locals.concat(LocalVariables.new(file: path).candidates(result.value))
      end
      reachability = Reachability.new(index, plugins: @plugins)
      candidates = reachability.candidates
      @acquittals = reachability.acquittals
      candidates + locals
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
