require 'test_helper'

# Integration specs for behaviour the tool SUPPORTS. Each runs the full pipeline
# (parse -> index -> reachability + locals) through candidates_for and asserts
# the end-to-end result, so this doubles as the catalogue of what works and as
# regression cover. The cases the tool deliberately does NOT support, and why,
# live in out_of_scope_test.rb.
class SupportedBehaviourTest < Minitest::Test
  # --- Local variables ---

  def test_unused_local_variables_are_reported
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

  # --- Inheritance and mixins ---

  def test_private_method_from_an_included_module_is_alive
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

  # --- Generated and class methods ---

  def test_methods_defined_via_define_method_are_tracked
    candidates = candidates_for(<<~RUBY)
      class Foo
        define_method(:dynamic) { 1 }
        private :dynamic
      end
    RUBY
    assert_equal [:dynamic], candidate_names(candidates)
  end

  def test_private_class_methods_are_analysed
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

  # --- Dispatch precision ---

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
  # Further gaps found by review, since implemented. The tag each carried
  # during triage (now preserved only in the commit messages):
  #   Bug         - wrong output, now fixed
  #   Not yet     - capability we had not built, now built
  #   Imprecision - coarse answer, now exact
  #   Robustness  - silent wrongness, now surfaced
  # ======================================================================

  # --- Reachability counts ANY caller, not a LIVE caller ----------------
  # The core check asks "is this method named in a call anywhere in the
  # hierarchy?" when it should ask "is it reachable from a root (a public
  # / entry-point method) through the call graph?". Dead code that only
  # calls itself, or other dead code, therefore hides from us. Fixing this
  # means building a call graph and marking from roots, not name-matching.

  def test_mutually_recursive_dead_private_methods_are_reported
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
    facts = facts_for(<<~RUBY, "Outer")
      class Outer
        Thing = Struct.new(:x) do
          def helper; end
        end
      end
    RUBY
    refute_includes facts.definitions.map(&:name), :helper
  end

  # --- Macro-generated and anonymous-class methods ---

  def test_unused_private_attr_reader_is_reported
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        attr_reader :secret
      end
    RUBY
    assert_equal [:secret], candidate_names(candidates)
  end

  def test_methods_defined_inside_an_anonymous_class_are_tracked
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

  # ======================================================================
  # Found by dogfooding the tool against a large Rails app (meetcleo).
  # Statically-fixable false positives: methods the Ruby runtime invokes
  # directly, so they (and the private helpers they reach) are not dead.
  # The fix is decidable and language-level: treat the runtime-hook names as
  # always-reachable roots. (Framework-invoked methods - Rails controller
  # hooks, serializer include_X? conventions, gem template methods - are a
  # different problem: the caller is outside the analysed code, the same open
  # call surface as public methods, which the runtime tier addresses.)
  # ======================================================================

  def test_initialize_is_a_reachable_root
    candidates = candidates_for(<<~RUBY)
      class Foo
        private

        def initialize
          setup
        end

        def setup; end
      end
    RUBY

    assert_empty candidates
  end

  def test_runtime_hook_methods_are_reachable_roots
    candidates = candidates_for(<<~RUBY)
      module M
        private

        def method_added(name)
          track(name)
        end

        def track(name); end
      end
    RUBY

    assert_empty candidates
  end
end
