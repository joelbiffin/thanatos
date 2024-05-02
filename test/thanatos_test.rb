require 'test_helper'

require_relative '../lib/thanatos.rb'

class ThanatosTest < Minitest::Test
  def test_single_class_method_definitions_and_called_are_stored
    thanatos = Thanatos.new(path: 'example/single_class.rb')
    thanatos.run

    method_calls = { 'Foo' => [:baz] }
    assert_equal method_calls, thanatos.method_calls

    public_methods = { 'Foo' => [:bar] }
    assert_equal public_methods, thanatos.method_definitions(:public)

    private_methods = { 'Foo' => [:baz, :baq] }
    assert_equal private_methods, thanatos.method_definitions(:private)

    unused_private_methods = { 'Foo' => [:baq] }
    assert_equal unused_private_methods, thanatos.unused_private_methods

    assert_equal 1, thanatos.constants.keys.length
    assert_equal ["Foo"], thanatos.constants.keys.sort
  end

  def test_two_classes_method_definitions_and_called_are_stored
    thanatos = Thanatos.new(path: 'example/two_classes.rb')
    thanatos.run

    method_calls = {
      'Foo' => [:baz],
      'Table' => []
    }
    assert_equal method_calls, thanatos.method_calls

    public_methods = {
      'Foo' => [:bar],
      'Table' => [:legs]
    }
    assert_equal public_methods, thanatos.method_definitions(:public)

    private_methods = {
      'Foo' => [:baz, :baq],
      'Table' => [:stuff]
    }
    assert_equal private_methods, thanatos.method_definitions(:private)

    unused_private_methods = {
      'Foo' => [:baq],
      'Table' => [:stuff]
    }
    assert_equal unused_private_methods, thanatos.unused_private_methods

    assert_equal 2, thanatos.constants.keys.length
    assert_equal ["Foo", "Table"], thanatos.constants.keys.sort
  end

  def test_multiple_classes_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/multiple_classes.rb')
    thanatos.run

    method_calls = {"Foo"=>[:baz], "Qux"=>[:baz]}
    assert_equal method_calls, thanatos.method_calls
    public_methods = {"Foo"=>[:bar, :baz, :baq], "Qux"=>[:bar, :baz, :baq]}
    assert_equal public_methods, thanatos.method_definitions(:public)
    assert_equal 2, thanatos.constants.keys.length
    assert_equal ["Foo", "Qux"], thanatos.constants.keys.sort
  end

  def test_singleton_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/singleton_methods.rb')
    thanatos.run
    method_calls = {"Foo" => [:baz]}
    assert_equal method_calls, thanatos.method_calls

    public_methods = {"Foo" => [:bar, :baz, :baq, :bar]}
    assert_equal public_methods, thanatos.method_definitions(:public)
    assert_equal 1, thanatos.constants.keys.length
    assert_equal ["Foo"], thanatos.constants.keys.sort
  end

  def test_multiple_classes_and_nested_namespace_method_definitions_and_calls_are_stored
    thanatos = Thanatos.new(path: 'example/multiple_classes_and_namespaces.rb')
    thanatos.run

    method_calls = {"Foo"=>[:baz], "Foo::Baz"=>[], "Foo::Baz::Bar"=>[], "Foo::Baz::Bar::Qux"=>[:baz], "Foo::Qux"=>[:baz]}
    assert_equal method_calls, thanatos.method_calls

    public_methods = {"Foo"=>[:bar, :baz, :baq], "Foo::Baz"=>[], "Foo::Baz::Bar"=>[], "Foo::Baz::Bar::Qux"=>[:bar, :baz, :baq], "Foo::Qux"=>[:bar, :baz, :baq]}
    assert_equal public_methods, thanatos.method_definitions(:public)
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

    public_methods = {"Foo"=>[:public_thing]}
    assert_equal public_methods, thanatos.method_definitions(:public)
    protected_method_definitions = {"Foo"=>[:protected_thing]}
    assert_equal protected_method_definitions, thanatos.method_definitions(:protected)
    private_method_definitions = {"Foo"=>[:private_thing]}
    assert_equal private_method_definitions, thanatos.method_definitions(:private)
    assert_equal 1, thanatos.constants.keys.length
  end
end

