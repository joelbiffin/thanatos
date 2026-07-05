module Thanatos
  class Configuration
    attr_reader :plugins

    def initialize
      @plugins = []
    end

    def register_plugin(plugin)
      @plugins << (plugin.is_a?(Class) ? plugin.new : plugin)
    end

    def reset!
      @plugins = []
    end
  end
end
