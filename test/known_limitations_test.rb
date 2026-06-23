require 'test_helper'

# These tests document the deliberate boundaries of this version of the tool.
# Each one is SKIPPED rather than deleted: the body is an executable spec of
# behaviour we do not yet provide, and every one would FAIL today if unskipped
# (so they are honest about the gap, not decorative). Removing a `skip` is the
# intended first step of implementing that capability.
class KnownLimitationsTest < Minitest::Test
  # --- Out of scope by design (a different tier, or solved elsewhere) ---

  def test_unused_local_variables_are_reported
    skip "Out of scope: local-variable liveness is delegated to `ruby -w` / RuboCop Lint/UselessAssignment, which already do it exactly."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call
          unused = compute_something
          42
        end
      end
    RUBY
    assert_includes candidate_names(candidates), :unused
  end

  def test_unused_public_methods_are_reported
    skip "Out of scope: public methods have an open call surface (routes, views, serializers, other gems). Sound detection needs a runtime/coverage tier, not static reachability."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def never_called_anywhere; end
      end
    RUBY
    assert_equal [:never_called_anywhere], candidate_names(candidates)
  end

  def test_unused_classes_and_modules_are_reported
    skip "Out of scope: constant (class/module) liveness needs constant-reference tracking and Rails autoload awareness, not method reachability."
    candidates = candidates_for(<<~RUBY)
      class NeverInstantiated
      end
    RUBY
    assert_equal ["NeverInstantiated"], candidates.map(&:fqn)
  end

  # --- Reachability gaps (false positives we knowingly accept for now) ---

  def test_private_method_from_an_included_module_is_alive
    skip "Not yet: reachability follows superclass inheritance only, not include/prepend. A concern's private method called from its includer is wrongly flagged dead - a significant gap for Rails."
    candidates = candidates_for(<<~RUBY)
      module Greeting
        private

        def hello
          "hi"
        end
      end

      class Person
        include Greeting

        def greet
          hello
        end
      end
    RUBY
    assert_empty candidates
  end

  def test_dynamically_computed_superclass_keeps_the_chain_linked
    skip "Not yet: a superclass introduced via Class.new / a computed constant produces no ClassNode, so the inheritance chain breaks and an inherited private looks dead."
    candidates = candidates_for(<<~RUBY)
      class Animal
        private

        def heartbeat
          "thump"
        end
      end

      Reptile = Class.new(Animal)

      class Snake < Reptile
        def alive?
          heartbeat
        end
      end
    RUBY
    assert_empty candidates
  end

  # --- Definition-tracking gaps (we only see lexical `def`) ---

  def test_methods_defined_via_define_method_are_tracked
    skip "Not yet: define_method creates no DefNode, so dynamically-defined methods are invisible to definition tracking (and so can never be reported as unused)."
    candidates = candidates_for(<<~RUBY)
      class Foo
        define_method(:dynamic) { 1 }
        private :dynamic
      end
    RUBY
    assert_equal [:dynamic], candidate_names(candidates)
  end

  def test_private_class_methods_are_analysed
    skip "Not yet: only instance-method visibility is modelled. `def self.x` and private_class_method are ignored (def with a receiver is skipped)."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def self.build
          new
        end

        private_class_method def self.secret_helper
        end
      end
    RUBY
    assert_equal [:secret_helper], candidate_names(candidates)
  end

  # --- Precision gaps (we downgrade where we could be exact) ---

  def test_send_with_a_literal_symbol_acquits_rather_than_downgrades
    skip "Imprecision: send(:literal) is a definite call, but is currently treated as a low-confidence hint (symbol literal + dynamic marker) instead of an outright acquittal."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call
          send(:helper)
        end

        private

        def helper; end
      end
    RUBY
    assert_empty candidates
  end
end
