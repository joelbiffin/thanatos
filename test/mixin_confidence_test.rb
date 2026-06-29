require 'test_helper'

# How a mixed-in module affects a candidate's confidence, across every
# permutation. Confidence follows the original "downgrade, don't hide" model: a
# method static reachability cannot reach is a candidate; if a dynamic-dispatch
# marker (a computed send/public_send/define_*) sits anywhere in its resolved
# hierarchy we cannot prove it dead, so it drops to :low, otherwise it is :high.
#
# Two rules drive every result below:
#   * the marker union walks the SAME-dimension hierarchy - the class, its
#     superclass chain, and included/prepended modules - but NOT extend; and
#   * only modules thanatos actually PARSED are in that hierarchy. An include of
#     a vendored / gem module thanatos never saw contributes nothing, so the
#     same includer can be :high vendored and :low once the module is in scope.
#
# These are characterization tests: they pin current behaviour, not an ideal.
class MixinConfidenceTest < Minitest::Test
  # --- No candidate at all (gated out before confidence is even considered) ---

  # Public methods have an open call surface; thanatos never reports them, even
  # when the class mixes in a computed-dispatch module.
  def test_public_method_is_never_a_candidate
    candidates = candidates_for(<<~RUBY)
      module Dispatcher
        def run(name)
          send(name)
        end
      end

      class Service
        include Dispatcher

        def unused_public; end
      end
    RUBY
    assert_empty candidates
  end

  # A private method reached from a public root in its own class is alive.
  def test_private_method_reached_in_its_own_class_is_not_a_candidate
    candidates = candidates_for(<<~RUBY)
      class Service
        def call
          helper
        end

        private

        def helper; end
      end
    RUBY
    assert_empty candidates
  end

  # Reachability spans parsed mixins: a public method in the module reaches the
  # includer's private method, so it is not dead.
  def test_private_method_reached_through_a_parsed_mixin_is_not_a_candidate
    candidates = candidates_for(<<~RUBY)
      module Runnable
        def run
          helper
        end
      end

      class Service
        include Runnable

        private

        def helper; end
      end
    RUBY
    assert_empty candidates
  end

  # --- High confidence: dead, and nothing casts dynamic-dispatch doubt ---

  def test_dead_private_with_no_mixins_is_high
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      class Service
        private

        def dead; end
      end
    RUBY
  end

  # A parsed mixin that performs no dynamic dispatch leaves confidence untouched.
  def test_dead_private_with_a_static_parsed_mixin_is_high
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Helpers
        def run
          ok
        end

        def ok; end
      end

      class Service
        include Helpers

        private

        def dead; end
      end
    RUBY
  end

  # A LITERAL send is a proof of call (it acquits :ok), not a dynamic marker, so
  # it never downgrades unrelated methods.
  def test_dead_private_with_a_mixin_using_only_literal_send_is_high
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Helpers
        def run
          send(:ok)
        end
      end

      class Service
        include Helpers

        private

        def dead; end
      end
    RUBY
  end

  # --- Low confidence: a computed dispatch in the hierarchy casts doubt ---

  def test_dead_private_with_an_included_computed_dispatch_module_is_low
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name)
          send(name)
        end
      end

      class Service
        include Dispatcher

        private

        def dead; end
      end
    RUBY
  end

  # prepend resolves into the same ancestor chain as include.
  def test_prepend_propagates_the_marker_like_include
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name)
          send(name)
        end
      end

      class Service
        prepend Dispatcher

        private

        def dead; end
      end
    RUBY
  end

  # The module that actually contains the dispatch has its own dead privates
  # downgraded by its own marker.
  def test_modules_own_dead_private_is_low
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name)
          send(name)
        end

        private

        def dead; end
      end
    RUBY
  end

  # The other downgrade path: a bare symbol matching the method name (callback /
  # delegate / send target?). No mixin involved.
  def test_symbol_literal_in_scope_downgrades
    assert_equal :low, confidence_of(<<~RUBY, :guarded)
      class Controller
        before_action :guarded

        private

        def guarded; end
      end
    RUBY
  end

  # --- Vendored vs in-app: identical includer, opposite verdict ---

  # The include only resolves if thanatos parsed the module. The SAME Service is
  # :high while Dispatcher is vendored (unseen) and :low once Dispatcher is
  # in-app (parsed) - so widening the scan can lower confidence.
  def test_vendored_module_does_not_downgrade_but_the_same_in_app_module_does
    includer = <<~RUBY
      class Service
        include Dispatcher

        private

        def dead; end
      end
    RUBY

    in_app_module = <<~RUBY
      module Dispatcher
        def run(name)
          send(name)
        end
      end
    RUBY

    assert_equal :high, confidence_of(includer, :dead)                    # Dispatcher vendored / unparsed
    assert_equal :low,  confidence_of(in_app_module + includer, :dead)    # Dispatcher in-app / parsed
  end

  # --- extend is not include: the marker union ignores the extend edge ---

  # extend mixes a module's instance methods onto the singleton side and DOES
  # feed singleton reachability, but the marker union walks only ancestors
  # (superclass + include/prepend). So an extended computed-dispatch module
  # leaves the extender's private CLASS methods at :high - asymmetric with
  # include above.
  def test_extend_does_not_propagate_the_dynamic_dispatch_marker
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name)
          send(name)
        end
      end

      class Service
        extend Dispatcher

        class << self
          private

          def dead; end
        end
      end
    RUBY
  end

  private

  def confidence_of(source, name)
    candidate = candidates_for(source).find { |c| c.name == name }
    refute_nil candidate, "expected #{name.inspect} to be reported as a candidate"
    candidate.confidence
  end
end
