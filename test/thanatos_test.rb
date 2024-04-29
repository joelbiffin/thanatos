require 'test_helper'

require_relative '../lib/thanatos.rb'

class ThanatosTest < Minitest::Test
  def test_single_class_method_definitions_and_called_are_stored
    thanatos = Thanatos.new(path: 'example/single_class.rb')
    thanatos.run

    assert_equal [:baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq], thanatos.method_definitions(:public)
    assert_equal 1, thanatos.constants.keys.length
    assert_equal ["Foo"], thanatos.constants.keys.sort
  end

  def test_multiple_classes_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/multiple_classes.rb')
    thanatos.run

    assert_equal [:baz, :baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq, :bar, :baz, :baq], thanatos.method_definitions(:public)
    assert_equal 2, thanatos.constants.keys.length
    assert_equal ["Foo", "Qux"], thanatos.constants.keys.sort
  end

  def test_singleton_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/singleton_methods.rb')
    thanatos.run

    assert_equal [:baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq, :bar], thanatos.method_definitions(:public)
    assert_equal 1, thanatos.constants.keys.length
    assert_equal ["Foo"], thanatos.constants.keys.sort
  end

  def test_multiple_classes_and_nested_namespace_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/multiple_classes_and_namespaces.rb')
    thanatos.run

    assert_equal [:baz, :baz, :baz], thanatos.method_calls
    assert_equal [:bar, :baz, :baq, :bar, :baz, :baq, :bar, :baz, :baq], thanatos.method_definitions(:public)
    assert_equal 5, thanatos.constants.keys.length
    assert_equal [
      "Foo",
      "Foo::Baz",
      "Foo::Baz::Bar",
      "Foo::Baz::Bar::Qux",
      "Foo::Qux",
    ], thanatos.constants.keys.sort
  end

  def test_private_methods_are_differentiated_from_public_ones
    thanatos = Thanatos.new(path: 'example/class_with_multiple_method_visibilities.rb')
    thanatos.run

    assert_equal [:public_thing], thanatos.method_definitions(:public)
    assert_equal [:protected_thing], thanatos.method_definitions(:protected)
    assert_equal [:private_thing], thanatos.method_definitions(:private)
    assert_equal 1, thanatos.constants.keys.length
  end
end

