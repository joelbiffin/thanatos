require "prism"
require "set"

require_relative "thanatos/method_definition"
require_relative "thanatos/candidate"
require_relative "thanatos/call_site"
require_relative "thanatos/reference_signals"
require_relative "thanatos/class_facts"
require_relative "thanatos/index"
require_relative "thanatos/index_builder"
require_relative "thanatos/index_builder/scope"
require_relative "thanatos/plugin"
require_relative "thanatos/reachability"
require_relative "thanatos/local_variables"
require_relative "thanatos/analyzer"
require_relative "thanatos/cli"

module Thanatos
  VERSION = "0.1.0"

  def self.analyze(*paths)
    Analyzer.new(paths: paths).call
  end
end
