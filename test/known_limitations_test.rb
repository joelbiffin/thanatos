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

  # ======================================================================
  # Further gaps found by review. Each behaviour below was confirmed to
  # reproduce against the current implementation. The tag in every skip
  # message is deliberate:
  #   Bug         - wrong output that should be fixed
  #   Not yet     - a capability we have chosen not to build (yet)
  #   Out of scope- intentionally another tool's/tier's job
  #   Imprecision - we answer, but more coarsely than we could
  #   Robustness  - we can be silently wrong with no warning
  # ======================================================================

  # --- Reachability counts ANY caller, not a LIVE caller ----------------
  # The core check asks "is this method named in a call anywhere in the
  # hierarchy?" when it should ask "is it reachable from a root (a public
  # / entry-point method) through the call graph?". Dead code that only
  # calls itself, or other dead code, therefore hides from us. Fixing this
  # means building a call graph and marking from roots, not name-matching.

  def test_mutually_recursive_dead_private_methods_are_reported
    skip "Bug: reachability treats any in-edge as alive. Two privates that only call each other are dead, but each is the other's caller, so neither is flagged."
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        def ping
          pong
        end

        def pong
          ping
        end
      end
    RUBY
    assert_equal [:ping, :pong], candidate_names(candidates)
  end

  def test_self_recursive_dead_private_method_is_reported
    skip "Bug: a private method whose only caller is itself counts as called, so a dead recursive helper is never flagged."
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        def recurse
          recurse
        end
      end
    RUBY
    assert_equal [:recurse], candidate_names(candidates)
  end

  def test_private_method_reachable_only_through_dead_code_is_reported
    skip "Bug: we catch a private with no caller, but not one whose only caller is itself dead. dead_b is 'called' by the (also dead) dead_a, so only dead_a is reported today."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def entry_point; end

        private

        def dead_a
          dead_b
        end

        def dead_b; end
      end
    RUBY
    assert_equal [:dead_a, :dead_b], candidate_names(candidates)
  end

  # --- Visibility / definitions leak across class-defining blocks -------
  # Visibility is reset only on class/module NODES, but Struct.new,
  # Class.new, class_eval and ActiveSupport::Concern's `class_methods do`
  # / `included do` blocks also change the definee. One root cause, two
  # symptoms: a visibility leak AND method misattribution.

  def test_private_inside_a_class_defining_block_does_not_leak_out
    skip "Bug: a `private` inside a Struct.new/Class.new/class_eval block flips the ENCLOSING class's visibility, because visibility resets only on class/module nodes. Here `b` is wrongly recorded as private and so would be reported as a dead private even if it is a used public method."
    facts = facts_for(<<~RUBY, "Outer")
      class Outer
        def a; end

        Thing = Struct.new(:x) do
          private

          def helper; end
        end

        def b; end
      end
    RUBY
    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :public, visibilities[:b]
  end

  def test_methods_in_a_class_defining_block_are_not_attributed_to_the_outer_class
    skip "Bug: a `def` inside a class-defining block is recorded against the enclosing class instead of the anonymous class it belongs to. `helper` here is wrongly attributed to Outer. The same happens for a concern's `class_methods do ... end`."
    facts = facts_for(<<~RUBY, "Outer")
      class Outer
        Thing = Struct.new(:x) do
          def helper; end
        end
      end
    RUBY
    refute_includes facts.definitions.map(&:name), :helper
  end

  # --- Methods we never see, so cannot flag -----------------------------

  def test_unused_private_attr_reader_is_reported
    skip "Not yet: attr_reader/writer/accessor generate methods with no DefNode, so an unused private attribute is invisible. Distinct from, and far more common than, define_method."
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        attr_reader :secret
      end
    RUBY
    assert_equal [:secret], candidate_names(candidates)
  end

  def test_methods_defined_inside_an_anonymous_class_are_tracked
    skip "Not yet: a body introduced via Class.new has no ClassNode, so a plain `def` inside it has no scope to attach to and is invisible. `unused` below is dead but never seen."
    candidates = candidates_for(<<~RUBY)
      Widget = Class.new do
        def call
          helper
        end

        private

        def helper; end

        def unused; end
      end
    RUBY
    assert_equal [:unused], candidate_names(candidates)
  end

  # --- Constant resolution & parse edges --------------------------------

  def test_absolute_constant_path_is_not_rescoped_under_a_module
    skip "Bug: `class ::Foo` defined inside `module A` is scoped to A::Foo instead of top-level Foo, because the leading `::` is ignored when building the fully-qualified name."
    index = index_for(<<~RUBY)
      module A
        class ::Foo
          def a; end
        end
      end
    RUBY
    refute_nil index["Foo"]
    assert_nil index["A::Foo"]
  end

  def test_conditional_visibility_modifier_is_not_applied_unconditionally
    skip "Imprecision: a guarded visibility modifier (`private if <cond>`) is treated as an unconditional flip; the runtime condition is ignored, so the following def is wrongly marked private."
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        private if false

        def still_public; end
      end
    RUBY
    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :public, visibilities[:still_public]
  end

  def test_a_redefined_method_is_reported_only_once
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        def dup_me; end
        def dup_me; end
      end
    RUBY
    assert_equal [:dup_me], candidate_names(candidates)
  end

  # --- Precision: symbols that are not really usage hints ----------------

  def test_method_object_reference_acquits_rather_than_downgrades
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call
          method(:helper)
        end

        private

        def helper; end
      end
    RUBY
    assert_empty candidates
  end

  def test_block_pass_symbol_does_not_falsely_downgrade_an_unrelated_method
    candidates = candidates_for(<<~RUBY)
      class Foo
        def call
          [1, 2].map(&:process)
        end

        private

        def process; end
      end
    RUBY
    candidate = candidates.find { |c| c.name == :process }
    assert_equal :high, candidate.confidence
  end

  # --- Robustness --------------------------------------------------------

  def test_parse_errors_are_collected_rather_than_silently_ignored
    analyzer = Thanatos::Analyzer.new(paths: [])
    assert_respond_to analyzer, :parse_errors
  end
end
