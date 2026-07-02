require 'test_helper'

# ClassFacts is the per-constant accumulator, tested directly (no parsing): how
# definitions resolve visibility marks and de-duplicate, how the call graph
# derives implicit_calls, and that instance and class methods stay separate.
class ClassFactsTest < Minitest::Test
  test "definitions apply visibility marks and dedupe keeping the last" do
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_definition(name: :dup, visibility: :public, location: "a:1")
    facts.add_definition(name: :dup, visibility: :public, location: "a:2")
    facts.mark_visibility(:dup, :private)

    defs = facts.definitions
    assert_equal 1, defs.length
    assert_equal :private, defs.first.visibility   # mark applied
    assert_equal "a:2", defs.first.location        # last definition wins
  end

  test "implicit_calls unions targets across all callers" do
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_call(:method_one, :a)
    facts.add_call(:method_two, :b)

    assert_equal Set[:a, :b], facts.implicit_calls
  end

  test "instance and singleton tables are separate" do
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_definition(name: :x, visibility: :private, location: "a:1")
    facts.add_singleton_definition(name: :x, visibility: :public, location: "a:2")

    assert_equal :private, facts.definitions.first.visibility
    assert_equal :public, facts.singleton_definitions.first.visibility
  end
end
