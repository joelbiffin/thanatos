require 'test_helper'

# Behaviour the tool deliberately does NOT support, and why. These specs are
# SKIPPED: each is provably undecidable for a purely static tool (Rice's theorem
# / the Computed-Token Lemma; see docs/undecidable-cases.md), so it needs the
# runtime / coverage tier rather than more static analysis. The body is the spec
# that tier would satisfy - kept executable so the boundary is not forgotten.
class OutOfScopeTest < Minitest::Test
  # Public methods have an open call surface (routes, views, serializers, other
  # gems, reflection); their liveness is not a function of the analysed source.
  def test_unused_public_methods_are_reported
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
  def test_unused_classes_and_modules_are_reported
    skip "Out of scope: constant (class/module) liveness needs constant-reference tracking and Rails autoload awareness, not method reachability."
    candidates = candidates_for(<<~RUBY)
      class NeverInstantiated
      end
    RUBY
    assert_equal ["NeverInstantiated"], candidates.map(&:fqn)
  end
end
