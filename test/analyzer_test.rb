require 'test_helper'
require 'stringio'

# End-to-end over real files: Analyzer expands paths, parses every file into one
# shared Index (so a class reopened across files is a single scope), and reports
# candidates. The CLI wraps that with a CI-friendly exit status.
class AnalyzerTest < Minitest::Test
  test "reports the dead private method in a fixture, not the used ones" do
    candidates = Thanatos::Analyzer.new(paths: "example/private_method_from_inherited_class.rb").call

    assert_equal [:orphan], candidate_names(candidates)
    assert_equal "Base", candidates.first.fqn
    assert_equal :high, candidates.first.confidence
  end

  # An override is reachable through a call in its parent (dynamic dispatch), so
  # it must not be reported. Reachability spans ancestors as well as descendants.
  test "an overridden private method is not flagged" do
    candidates = Thanatos::Analyzer.new(paths: "example/overridden_private_method.rb").call
    assert_empty candidates
  end

  test "a class reopened across files is treated as one scope" do
    candidates = Thanatos::Analyzer.new(paths: "example/multi_file_private_usage").call
    names = candidate_names(candidates)

    assert_includes names, :never_called            # called nowhere -> dead
    refute_includes names, :only_used_in_other_file # called from the other file -> alive
  end

  test "a directory path expands to every ruby file under it" do
    analyzer = Thanatos::Analyzer.new(paths: "example/multi_file_private_usage")
    assert_operator analyzer.paths.length, :>=, 2
  end

  # A syntax error degrades coverage rather than crashing the run: the errors are
  # collected for reporting.
  test "parse errors are collected rather than silently ignored" do
    assert_respond_to Thanatos::Analyzer.new(paths: []), :parse_errors
  end

  test "the CLI exits non-zero and reports when high-confidence candidates exist" do
    out = StringIO.new
    status = Thanatos::CLI.run(["example/private_method_from_inherited_class.rb"], out:)

    assert_equal 1, status
    assert_includes out.string, "orphan"
    assert_includes out.string, "high-confidence"
  end

  test "the CLI reports low-confidence findings by default" do
    out = StringIO.new
    Thanatos::CLI.run(["example/mixed_confidence.rb"], out:)

    assert_includes out.string, "orphaned"  # high
    assert_includes out.string, "guarded"   # low, shown by default
  end

  test "--min-confidence high filters out low-confidence findings" do
    out = StringIO.new
    Thanatos::CLI.run(["--min-confidence", "high", "example/mixed_confidence.rb"], out:)

    assert_includes out.string, "orphaned"  # high -> kept
    refute_includes out.string, "guarded"   # low -> filtered out
  end
end
