require 'test_helper'

# Behaviour Thanatos deliberately does NOT support, and why. These specs are
# SKIPPED: each is provably undecidable for a purely static tool (see
# docs/decidability.md), so it needs a runtime / coverage tier rather than more
# static analysis. The body is kept executable so the boundary is not forgotten.
class OutOfScopeTest < Minitest::Test
  # Public methods have an open call surface (routes, views, serializers, other
  # gems, reflection); their liveness is not a function of the analysed source.
  test "unused public methods are reported" do
    skip "Out of scope: public methods have an open call surface. Sound detection needs a runtime/coverage tier, not static reachability."
    candidates = candidates_for(<<~RUBY)
      class Foo
        def never_called_anywhere; end
      end
    RUBY
    assert_equal [:never_called_anywhere], candidate_names(candidates)
  end

  # Class/module liveness needs constantize / autoload / STI awareness - a
  # constant's references are computed at runtime, not visible in the source.
  test "unused classes and modules are reported" do
    skip "Out of scope: constant (class/module) liveness needs constant-reference tracking and Rails autoload awareness, not method reachability."
    candidates = candidates_for(<<~RUBY)
      class NeverInstantiated
      end
    RUBY
    assert_equal ["NeverInstantiated"], candidates.map(&:fqn)
  end
end
