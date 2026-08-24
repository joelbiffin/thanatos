require 'test_helper'

class ReachTest < Minitest::Test
  test ":public and :none reach nothing (a private candidate is never public)" do
    refute Thanatos::Reach.new(:public).reaches?(:anything)
    refute Thanatos::Reach.new(:none).reaches?(:anything)
  end

  test "a Regexp reaches the names it matches" do
    reach = Thanatos::Reach.new(/\Aon_/)

    assert reach.reaches?(:on_click)
    refute reach.reaches?(:unrelated)
  end

  test "a name list reaches its members, whether given as strings or symbols" do
    reach = Thanatos::Reach.new(%w[foo bar])

    assert reach.reaches?(:foo)
    refute reach.reaches?(:baz)
  end

  test "an unsupported reach spec raises, rather than silently reaching nothing" do
    error = assert_raises(ArgumentError) { Thanatos::Reach.new(:publik) }
    assert_includes error.message, "publik"
  end
end
