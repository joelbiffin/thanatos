require 'test_helper'

# The IndexBuilder walks a Prism AST and records, per constant scope, the facts
# Tier 1 needs: method definitions (with visibility), the calls made, bare symbol
# literals, and any dynamic-dispatch markers. It does NOT decide what is unused -
# that is Reachability's job. These tests pin down what the builder observes.
class IndexBuilderTest < Minitest::Test
  def test_partitions_definitions_by_ambient_visibility
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a; end
        protected
        def b; end
        private
        def c; end
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal({ a: :public, b: :protected, c: :private }, visibilities)
  end

  def test_private_with_symbol_argument_marks_only_that_method
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a; end
        def b; end
        private :b
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :public, visibilities[:a]
    assert_equal :private, visibilities[:b]
  end

  # `private def x` returns the symbol and marks x; it does NOT flip the ambient
  # visibility, so the following def stays public.
  def test_inline_private_def_marks_one_method_without_flipping_mode
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        private def a; end
        def b; end
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :private, visibilities[:a]
    assert_equal :public, visibilities[:b]
  end

  # A symbol passed to a visibility modifier is bookkeeping, not a usage, so it
  # must not pollute the symbol-literal set (which Reachability treats as a hint
  # that a method is reached dynamically).
  def test_symbol_argument_to_modifier_is_not_recorded_as_a_literal
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def b; end
        private :b
      end
    RUBY

    refute_includes facts.symbol_literals, :b
  end

  def test_separates_implicit_self_and_explicit_calls
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a
          helper
          self.thing
          collaborator.external
        end
      end
    RUBY

    assert_includes facts.implicit_calls, :helper
    assert_includes facts.implicit_calls, :thing
    assert_includes facts.explicit_calls, :external
    refute_includes facts.implicit_calls, :external
  end

  def test_records_dynamic_dispatch_markers
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a; send(:something); end
      end
    RUBY

    assert_includes facts.dynamic_markers, :send
  end

  # Both alias forms count as a use of the original method: `alias_method` (a
  # method call) and the `alias` keyword (an AliasMethodNode).
  def test_an_alias_counts_as_a_use_of_the_original_method
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def original; end
        def other; end
        alias_method :renamed, :original
        alias aliased other
      end
    RUBY

    assert_includes facts.implicit_calls, :original
    assert_includes facts.implicit_calls, :other
  end

  def test_builds_fully_qualified_names_for_nested_namespaces
    index = index_for(<<~RUBY)
      module Outer
        class Inner
          def a; end
        end
      end
    RUBY

    refute_nil index["Outer::Inner"]
    assert_equal [:a], index["Outer::Inner"].definitions.map(&:name)
  end

  def test_resolves_a_superclass_within_its_enclosing_namespace
    index = index_for(<<~RUBY)
      module M
        class Base; end
        class Child < Base; end
      end
    RUBY
    index.resolve_inheritance!

    assert_equal "M::Base", index["M::Child"].superclass_fqn
    assert_equal ["M::Child"], index.descendants("M::Base").map(&:fqn)
  end
end
