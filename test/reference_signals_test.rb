require 'test_helper'

# ReferenceSignals collects the hints, gathered from the source, that a method
# might be reached in a way plain reachability can't see: a bare symbol literal
# (a callback/send target), a dynamic-dispatch marker, and a structured call
# site (raw material for plugins). It also owns how those hints render as the
# doubt-reasons that downgrade a candidate to :low confidence.
class ReferenceSignalsTest < Minitest::Test
  def signals
    @signals ||= Thanatos::ReferenceSignals.new
  end

  def definition(name)
    Thanatos::MethodDefinition.new(name:, visibility: :private, location: "(inline):1")
  end

  test "records symbol literals, dynamic markers, and call sites" do
    signals.record_symbol_literal(:foo)
    signals.record_dynamic_marker(:send)
    signals.record_call_site(name: :guard, positional: [:foo], kwargs: { if: [:bar] })

    assert_includes signals.symbol_literals, :foo
    assert_includes signals.dynamic_markers, :send
    assert_equal :guard, signals.call_sites.first.name
    assert_equal({ if: [:bar] }, signals.call_sites.first.kwargs)
  end

  test "merge folds another set of signals in" do
    signals.record_symbol_literal(:foo)
    other = Thanatos::ReferenceSignals.new
    other.record_symbol_literal(:bar)
    other.record_dynamic_marker(:public_send)

    signals.merge(other)

    assert_equal %i[bar foo], signals.symbol_literals.to_a.sort
    assert_includes signals.dynamic_markers, :public_send
  end

  test "a matching symbol literal raises a reason for that method" do
    signals.record_symbol_literal(:foo)

    assert_includes signals.reasons_for(definition(:foo)),
      "referenced as symbol literal :foo (callback/delegate/send?)"
  end

  test "a symbol literal for another name raises no reason" do
    signals.record_symbol_literal(:foo)

    assert_empty signals.reasons_for(definition(:bar))
  end

  test "any dynamic marker taints every method, listing the markers sorted" do
    signals.record_dynamic_marker(:send)
    signals.record_dynamic_marker(:define_method)

    assert_includes signals.reasons_for(definition(:anything)),
      "class uses dynamic dispatch (define_method, send)"
  end

  test "reasons are ordered symbol-literal then dynamic-dispatch" do
    signals.record_symbol_literal(:foo)
    signals.record_dynamic_marker(:send)

    assert_equal [
      "referenced as symbol literal :foo (callback/delegate/send?)",
      "class uses dynamic dispatch (send)",
    ], signals.reasons_for(definition(:foo))
  end
end
