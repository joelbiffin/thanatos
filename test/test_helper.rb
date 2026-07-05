require 'debug'
require 'minitest/autorun'
require 'minitest/reporters'

require_relative '../lib/thanatos'

Minitest::Reporters.use!

module BuildHelpers
  def index_for(source)
    index = Thanatos::Index.new
    Thanatos::IndexBuilder.new(index, file: "(inline)").visit(Prism.parse(source).value)
    index
  end

  def facts_for(source, fqn)
    index_for(source)[fqn]
  end

  def candidates_for(source, plugins: [])
    program = Prism.parse(source).value
    index = Thanatos::Index.new
    Thanatos::IndexBuilder.new(index, file: "(inline)").visit(program)
    Thanatos::Reachability.new(index, plugins:).candidates +
      Thanatos::LocalVariables.new(file: "(inline)").candidates(program)
  end

  def candidate_names(candidates)
    candidates.map(&:name).sort
  end
end

class Minitest::Test
  include BuildHelpers

  # Configuration is a global singleton; keep tests independent of each other.
  def before_setup
    super
    Thanatos.configuration.reset!
  end

  # A readable-description test macro (like ActiveSupport::TestCase.test, but
  # self-defined so we take no dependency): `test "does the thing" do ... end`.
  # The description is the spec, so most tests need no comment.
  def self.test(description, &block)
    define_method("test_#{description.gsub(/\W+/, '_')}", &block)
  end
end
