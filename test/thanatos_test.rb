require 'test_helper'

require_relative '../lib/thanatos.rb'

class ThanatosTest < Minitest::Test
  def test_single_class_method_definitions_and_called_are_stored
    thanatos = Thanatos.new(path: 'example/single_class.rb')
    thanatos.run

    assert_equal [:baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq], thanatos.method_definitions
  end

  def test_multiple_classes_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/multiple_classes.rb')
    thanatos.run
    
    assert_equal [:baz, :baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq, :bar, :baz, :baq], thanatos.method_definitions
  end
end

