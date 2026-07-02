require 'test_helper'

# How a mixed-in module affects a candidate's confidence, across every
# permutation. Confidence follows "downgrade, don't hide": a method reachability
# cannot reach is a candidate; if a dynamic-dispatch marker (a computed
# send/public_send/define_*) sits anywhere in its resolved hierarchy we cannot
# prove it dead, so it drops to :low, otherwise :high. Two rules drive it:
#   * the marker union walks the SAME-dimension hierarchy (class + superclass
#     chain + included/prepended modules) but NOT extend; and
#   * only PARSED modules are in that hierarchy - an include of a vendored/gem
#     module Thanatos never saw contributes nothing.
# Characterization tests: they pin current behaviour, not an ideal.
class MixinConfidenceTest < Minitest::Test
  # --- No candidate at all (gated out before confidence is considered) ---

  test "a public method is never a candidate, even with a dispatch module mixed in" do
    candidates = candidates_for(<<~RUBY)
      module Dispatcher
        def run(name); send(name); end
      end

      class Service
        include Dispatcher
        def unused_public; end
      end
    RUBY
    assert_empty candidates
  end

  test "a private method reached in its own class is not a candidate" do
    candidates = candidates_for(<<~RUBY)
      class Service
        def call; helper; end
        private
        def helper; end
      end
    RUBY
    assert_empty candidates
  end

  test "a private method reached through a parsed mixin is not a candidate" do
    candidates = candidates_for(<<~RUBY)
      module Runnable
        def run; helper; end
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

  test "a dead private with no mixins is high confidence" do
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      class Service
        private
        def dead; end
      end
    RUBY
  end

  test "a dead private with a static parsed mixin is high confidence" do
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Helpers
        def run; ok; end
        def ok; end
      end

      class Service
        include Helpers
        private
        def dead; end
      end
    RUBY
  end

  # A LITERAL send is a proof of call (it acquits :ok), not a marker, so it never
  # downgrades unrelated methods.
  test "a dead private with a mixin using only literal send is high confidence" do
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Helpers
        def run; send(:ok); end
      end

      class Service
        include Helpers
        private
        def dead; end
      end
    RUBY
  end

  # --- Low confidence: a computed dispatch in the hierarchy casts doubt ---

  test "a dead private with an included computed-dispatch module is low confidence" do
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name); send(name); end
      end

      class Service
        include Dispatcher
        private
        def dead; end
      end
    RUBY
  end

  test "prepend propagates the dispatch marker like include" do
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name); send(name); end
      end

      class Service
        prepend Dispatcher
        private
        def dead; end
      end
    RUBY
  end

  test "the dispatch module's own dead private is low confidence" do
    assert_equal :low, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name); send(name); end
        private
        def dead; end
      end
    RUBY
  end

  # The other downgrade path: a bare symbol matching the name (callback/delegate/
  # send target?). No mixin involved.
  test "a matching symbol literal in scope downgrades" do
    assert_equal :low, confidence_of(<<~RUBY, :guarded)
      class Controller
        before_action :guarded
        private
        def guarded; end
      end
    RUBY
  end

  # --- Vendored vs in-app: identical includer, opposite verdict ---

  # The include only resolves if Thanatos parsed the module, so the same Service
  # is :high while Dispatcher is vendored and :low once it is in scope - widening
  # the scan can lower confidence.
  test "a vendored module does not downgrade, but the same in-app module does" do
    includer = <<~RUBY
      class Service
        include Dispatcher
        private
        def dead; end
      end
    RUBY

    in_app_module = <<~RUBY
      module Dispatcher
        def run(name); send(name); end
      end
    RUBY

    assert_equal :high, confidence_of(includer, :dead)                 # vendored / unparsed
    assert_equal :low,  confidence_of(in_app_module + includer, :dead) # in-app / parsed
  end

  # --- extend is not include: the marker union ignores the extend edge ---

  # extend feeds singleton reachability but the marker union walks only ancestors
  # (superclass + include/prepend), so an extended dispatch module leaves the
  # extender's private CLASS methods at :high - asymmetric with include.
  test "extend does not propagate the dynamic-dispatch marker" do
    assert_equal :high, confidence_of(<<~RUBY, :dead)
      module Dispatcher
        def run(name); send(name); end
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
