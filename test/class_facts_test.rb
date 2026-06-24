require 'test_helper'

# ClassFacts is the per-constant accumulator. These pin its behaviour directly
# (no parsing): how definitions resolve marks and de-duplicate, how the call
# graph derives implicit_calls, and that instance and class methods are kept in
# separate tables.
class ClassFactsTest < Minitest::Test
  def test_definitions_apply_visibility_marks_and_dedupe_keeping_the_last
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_definition(name: :dup, visibility: :public, location: "a:1")
    facts.add_definition(name: :dup, visibility: :public, location: "a:2")
    facts.mark_visibility(:dup, :private)

    defs = facts.definitions
    assert_equal 1, defs.length
    assert_equal :private, defs.first.visibility   # mark applied
    assert_equal "a:2", defs.first.location        # last definition wins
  end

  def test_implicit_calls_unions_targets_across_all_callers
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_call(:method_one, :a)
    facts.add_call(:method_two, :b)

    assert_equal Set[:a, :b], facts.implicit_calls
  end

  def test_instance_and_singleton_tables_are_separate
    facts = Thanatos::ClassFacts.new("Foo")
    facts.add_definition(name: :x, visibility: :private, location: "a:1")
    facts.add_singleton_definition(name: :x, visibility: :public, location: "a:2")

    assert_equal :private, facts.definitions.first.visibility
    assert_equal :public, facts.singleton_definitions.first.visibility
  end
end
