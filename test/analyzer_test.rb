require 'test_helper'
require 'stringio'

# End-to-end coverage over real files: the Analyzer expands paths, parses every
# file into one shared Index (so a class reopened across files is a single
# scope), and reports candidates. The CLI wraps that with a CI-friendly exit
# status.
class AnalyzerTest < Minitest::Test
  def test_inherited_private_method_fixture
    candidates = Thanatos::Analyzer.new(
      paths: "example/private_method_from_inherited_class.rb"
    ).call

    # Base#setup is called by Base#perform and Worker#run; Base#orphan never is.
    assert_equal [:orphan], candidate_names(candidates)
    assert_equal "Base", candidates.first.fqn
    assert_equal :high, candidates.first.confidence
  end

  # An override is reachable through a call in its parent (dynamic dispatch), so
  # it must not be reported. Reachability spans ancestors as well as descendants.
  def test_overridden_private_method_is_not_flagged
    candidates = Thanatos::Analyzer.new(paths: "example/overridden_private_method.rb").call
    assert_empty candidates
  end

  def test_class_reopened_across_files_is_treated_as_one_scope
    candidates = Thanatos::Analyzer.new(paths: "example/multi_file_private_usage").call
    names = candidate_names(candidates)

    # Called from the other file -> alive. Called from nowhere -> dead.
    assert_includes names, :never_called
    refute_includes names, :only_used_in_other_file
  end

  def test_directory_path_expands_to_every_ruby_file
    analyzer = Thanatos::Analyzer.new(paths: "example/multi_file_private_usage")
    assert_operator analyzer.paths.length, :>=, 2
  end

  def test_cli_exits_nonzero_and_reports_when_high_confidence_candidates_exist
    out = StringIO.new
    status = Thanatos::CLI.run(["example/private_method_from_inherited_class.rb"], out:)

    assert_equal 1, status
    assert_includes out.string, "orphan"
    assert_includes out.string, "high-confidence"
  end
end
