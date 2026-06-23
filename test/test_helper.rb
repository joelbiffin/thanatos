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

  def candidates_for(source)
    Thanatos::Reachability.new(index_for(source)).candidates
  end

  def candidate_names(candidates)
    candidates.map(&:name).sort
  end
end

class Minitest::Test
  include BuildHelpers
end
