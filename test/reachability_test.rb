require 'test_helper'

# Reachability turns an Index into a list of Candidates. The rule for this tier:
# a private/protected method is a candidate unless it is reachable from a root -
# a public method, the class body, or a Ruby runtime hook - by following calls
# through its hierarchy (superclass, includes, extends). Dynamic signals don't
# suppress a candidate outright; they downgrade its confidence to :low and
# explain why, because in a standalone static tool they are the only defence
# against the false positives that callbacks/send/metaprogramming would cause.
class ReachabilityTest < Minitest::Test
  def test_unused_private_method_is_a_high_confidence_candidate
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call; end
        private
        def dead; end
      end
    RUBY

    assert_equal 1, candidates.length
    candidate = candidates.first
    assert_equal "Foo", candidate.fqn
    assert_equal :dead, candidate.name
    assert_equal :private, candidate.visibility
    assert_equal :high, candidate.confidence
    assert_empty candidate.reasons
  end

  def test_internally_called_private_method_is_not_a_candidate
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call; helper; end
        private
        def helper; end
      end
    RUBY

    assert_empty candidates
  end

  # This tier deliberately ignores public methods: their call surface is open
  # (routes, views, other gems), so static analysis cannot speak to them.
  def test_public_methods_are_out_of_scope
    candidates = candidates_for(<<~RUBY)
      class Foo
        def maybe_unused; end
      end
    RUBY

    assert_empty candidates
  end

  # A private method can be invoked from a subclass, so reachability spans
  # descendants as well as the class itself (and ancestors, and mixins).
  def test_inherited_private_method_called_from_subclass_is_not_a_candidate
    candidates = candidates_for(<<~RUBY)
      class Base
        private
        def used_by_child; end
        def truly_dead; end
      end

      class Child < Base
        def go; used_by_child; end
      end
    RUBY

    assert_equal [:truly_dead], candidate_names(candidates)
    assert_equal "Base", candidates.first.fqn
  end

  def test_symbol_literal_reference_downgrades_to_low_confidence
    candidates = candidates_for(<<~RUBY)
      class Foo
        before_action :guard
        private
        def guard; end
      end
    RUBY

    assert_equal 1, candidates.length
    candidate = candidates.first
    assert_equal :guard, candidate.name
    assert_equal :low, candidate.confidence
    assert_includes candidate.reasons.first, "symbol literal"
  end

  def test_dynamic_dispatch_in_class_downgrades_to_low_confidence
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call; send(some_name); end
        private
        def maybe_used; end
      end
    RUBY

    candidate = candidates.find { |c| c.name == :maybe_used }
    assert_equal :low, candidate.confidence
    assert(candidate.reasons.any? { |r| r.include?("dynamic dispatch") })
  end

  def test_unused_protected_method_is_a_candidate
    candidates = candidates_for(<<~RUBY)
      class Foo
        protected
        def dead; end
      end
    RUBY

    assert_equal [:dead], candidate_names(candidates)
    assert_equal :protected, candidates.first.visibility
  end

  # Protected methods are legally callable with an explicit receiver from within
  # the hierarchy; we cannot prove the receiver's type, so a matching explicit
  # call from within the hierarchy downgrades rather than confirms.
  def test_protected_method_with_matching_explicit_call_is_downgraded
    candidates = candidates_for(<<~RUBY)
      class Comparable
        protected
        def score; end
      end

      class Caller < Comparable
        def compare(other); other.score; end
      end
    RUBY

    candidate = candidates.find { |c| c.name == :score }
    refute_nil candidate
    assert_equal :low, candidate.confidence
    assert(candidate.reasons.any? { |r| r.include?("explicit call") })
  end

  # Instance methods and class methods are separate method tables. A method of
  # one kind must not keep a same-named method of the other kind alive, and the
  # two must not collapse into one candidate.
  def test_public_class_method_does_not_keep_a_dead_private_instance_method_alive
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        def helper; end       # dead private instance method

        def self.helper; end  # unrelated public class method, same name
      end
    RUBY

    assert_equal [:helper], candidate_names(candidates)
  end

  def test_public_instance_method_does_not_keep_a_dead_private_class_method_alive
    candidates = candidates_for(<<~RUBY)
      class Foo
        private_class_method def self.helper; end  # dead private class method

        def helper; end                            # unrelated public instance method
      end
    RUBY

    assert_equal [:helper], candidate_names(candidates)
  end

  # `Receiver.class_eval do ... end` (literal receiver) reopens Receiver, so its
  # defs belong to Receiver and its `private` applies there - not to the
  # enclosing scope, and not lost when there is no enclosing class.
  def test_methods_added_via_class_eval_are_attributed_to_the_receiver
    candidates = candidates_for(<<~RUBY)
      class Widget
      end

      Widget.class_eval do
        private

        def helper; end
      end
    RUBY

    assert_equal [:helper], candidate_names(candidates)
  end

  # Protected methods are callable only within the class hierarchy, so an
  # explicit call from an unrelated class is not a legitimate use and must not
  # downgrade the finding.
  def test_protected_method_not_downgraded_by_an_unrelated_explicit_call
    candidates = candidates_for(<<~RUBY)
      class Measured
        protected
        def score; end
      end

      class Unrelated
        def rank(other)
          other.score
        end
      end
    RUBY

    candidate = candidates.find { |c| c.name == :score }
    refute_nil candidate
    assert_equal :high, candidate.confidence
  end

  # `extend M` mixes M's INSTANCE methods into the extender's SINGLETON table, so
  # a private method of M reached from the extender's class-method context is
  # alive (a cross-dimension link).
  def test_method_in_an_extended_module_used_by_a_class_method_is_alive
    candidates = candidates_for(<<~RUBY)
      module Helpers
        private

        def helper; end
      end

      class Foo
        extend Helpers

        def self.run
          helper
        end
      end
    RUBY

    assert_empty candidates
  end

  # ...but a genuinely-dead method in an extended module is still reported.
  def test_genuinely_dead_method_in_an_extended_module_is_reported
    candidates = candidates_for(<<~RUBY)
      module Helpers
        private

        def unused_helper; end
      end

      class Foo
        extend Helpers

        def self.run
          something_else
        end
      end
    RUBY

    assert_equal [:unused_helper], candidate_names(candidates)
  end

  # `extend self`: the module's instance methods are also its singleton methods,
  # so a public one is a root that keeps its private helpers alive.
  def test_extend_self_keeps_module_function_helpers_alive
    candidates = candidates_for(<<~RUBY)
      module Toolkit
        extend self

        def run
          helper
        end

        private

        def helper; end
      end
    RUBY

    assert_empty candidates
  end
end
