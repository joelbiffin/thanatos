require 'test_helper'

# Reachability turns an Index into a list of Candidates. The rule for this tier:
# a private/protected method is a candidate unless it is called (implicitly/via
# self) somewhere in its class or a descendant. Dynamic signals don't suppress a
# candidate outright - they downgrade its confidence to :low and explain why -
# because in a standalone static tool they are the only defence against the
# false positives that callbacks/send/metaprogramming would otherwise cause.
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

  # A private method can be invoked from a subclass, so reachability spans the
  # class plus its descendants.
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

  # Protected methods are legally callable with an explicit receiver, and we
  # cannot prove the receiver's type statically, so a matching explicit call
  # anywhere downgrades rather than confirms.
  def test_protected_method_with_matching_explicit_call_is_downgraded
    candidates = candidates_for(<<~RUBY)
      class Comparable
        protected
        def score; end
      end

      class Caller
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
end
