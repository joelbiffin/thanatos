require 'test_helper'

class CandidateTest < Minitest::Test
  def candidate(confidence)
    Thanatos::Candidate.new(fqn: "Foo", name: :bar, visibility: :private, location: "(inline):1", confidence:, reasons: [])
  end

  test "meets? orders the confidence levels low < medium < high" do
    assert candidate(:high).meets?(:low)
    assert candidate(:high).meets?(:high)
    refute candidate(:low).meets?(:high)

    assert candidate(:medium).meets?(:low)
    assert candidate(:medium).meets?(:medium)
    refute candidate(:medium).meets?(:high)
  end

  test "gating? is true only for the top, build-failing level" do
    assert candidate(:high).gating?
    refute candidate(:medium).gating?
    refute candidate(:low).gating?
  end
end
