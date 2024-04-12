require 'test_helper'

require_relative '../lib/thanatos.rb'

class ThanatosTest < Minitest::Test
  def test_method_definitions_and_called_are_stored
    thanatos = Thanatos.new(path: 'example/foo.rb')
    thanatos.run
    
    assert_equal [:baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq], thanatos.method_definitions
  end
end

