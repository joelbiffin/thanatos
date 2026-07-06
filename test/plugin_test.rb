require 'test_helper'

class PluginTest < Minitest::Test
  class DemoCallbacks < Thanatos::Plugin
    inherits_from "ApplicationController"

    reference_macro :guard,
      positional: "invoked as a %{macro} callback",
      kwargs: { if: "invoked as the %{macro} :if guard" },
      default_kwarg: "referenced in %{macro} %{key}:"
  end

  class Gating < Minitest::Test
    test "a plugin with no inherits_from applies to every class" do
      plugin = Class.new(Thanatos::Plugin).new
      index = index_for("class Anything; end")
      index.resolve_inheritance!
      assert plugin.applies_to?(index, "Anything")
    end

    test "a gated plugin applies to a descendant of the declared base" do
      index = index_for(<<~RUBY)
        class ApplicationController; end
        class PostsController < ApplicationController; end
      RUBY
      index.resolve_inheritance!
      assert DemoCallbacks.new.applies_to?(index, "PostsController")
    end

    test "a gated plugin does not apply to an unrelated class" do
      index = index_for("class ReportBuilder; end")
      index.resolve_inheritance!
      refute DemoCallbacks.new.applies_to?(index, "ReportBuilder")
    end

    test "gating follows the written superclass chain beyond scope" do
      index = index_for(<<~RUBY)
        class ApplicationController < ActionController::Base; end
        class PostsController < ApplicationController; end
      RUBY
      index.resolve_inheritance!
      plugin = Class.new(Thanatos::Plugin) { inherits_from "ActionController::Base" }.new
      assert plugin.applies_to?(index, "PostsController")
    end
  end

  class ReasonExtraction < Minitest::Test
    test "reference_macro maps positional, named-kwarg, and arbitrary-kwarg symbols to reasons" do
      facts = facts_for(<<~RUBY, "PostsController")
        class PostsController
          guard :authenticate, if: :logged_out?, only: :show
        end
      RUBY

      reasons = DemoCallbacks.new.reasons_for_class(facts)

      assert_includes reasons, [:authenticate, "invoked as a guard callback"]
      assert_includes reasons, [:logged_out?, "invoked as the guard :if guard"]
      assert_includes reasons, [:show, "referenced in guard only:"]
    end
  end

  class DeclarativeMacro < Minitest::Test
    SOURCE = <<~RUBY
      class ApplicationController; end
      class PostsController < ApplicationController
        guard :authenticate, if: :logged_out?
        def index; end
        private
        def authenticate; end
        def logged_out?; end
      end
    RUBY

    def reasons_for(candidates, name)
      candidates.find { |candidate| candidate.name == name }.reasons
    end

    test "the plugin attaches its specific, macro-aware reason to the callback methods" do
      candidates = candidates_for(SOURCE, plugins: [DemoCallbacks.new])

      assert_includes reasons_for(candidates, :authenticate), "invoked as a guard callback"
      assert_includes reasons_for(candidates, :logged_out?), "invoked as the guard :if guard"
    end

    test "the gate holds: no plugin reason for the same call in a non-descendant" do
      candidates = candidates_for(<<~RUBY, plugins: [DemoCallbacks.new])
        class ReportBuilder
          guard :authenticate
          def call; end
          private
          def authenticate; end
        end
      RUBY

      refute_includes reasons_for(candidates, :authenticate), "invoked as a guard callback"
    end
  end

  class Acquit < Minitest::Test
    class GuardPlugin < Thanatos::Plugin
      inherits_from "Machine"
      invokes :guarded, kwargs: %i[unless]
    end

    SOURCE = <<~RUBY
      class Machine; end
      class Account < Machine
        guarded to: :frozen, unless: :barable?
        def call; end
        private
        def barable?; end
        def orphan; end
      end
    RUBY

    test "without the plugin the guard method is only a low-confidence candidate" do
      candidate = candidates_for(SOURCE).find { |c| c.name == :barable? }

      refute_nil candidate
      assert_equal :low, candidate.confidence
    end

    test "invokes acquits the guard method so it is not a candidate at all" do
      names = candidates_for(SOURCE, plugins: [GuardPlugin.new]).map(&:name)

      refute_includes names, :barable?    # definitely called → removed
      assert_includes names, :orphan       # unrelated dead method still flagged
    end

    test "the acquitted method is reported with provenance" do
      entry = acquittals_for(SOURCE, plugins: [GuardPlugin.new]).find { |a| a.name == :barable? }

      refute_nil entry
      assert_equal "Account", entry.fqn
      assert entry.sources.any? { |s| s.include?("GuardPlugin") && s.include?("guarded") }
    end

    test "a redundant acquit (the method is also really called) is not reported" do
      source = <<~RUBY
        class Machine; end
        class Account < Machine
          guarded unless: :barable?
          def call; barable?; end
          private
          def barable?; end
        end
      RUBY

      assert_empty acquittals_for(source, plugins: [GuardPlugin.new])
    end
  end

  class ArbitraryPlugin < Minitest::Test
    class SchedulerPlugin < Thanatos::Plugin
      inherits_from "ScheduledTask"

      def reasons_for_class(facts)
        [[:run, "invoked by the scheduler (convention)"]]
      end
    end

    SOURCE = <<~RUBY
      class ScheduledTask; end
      class Cleanup < ScheduledTask
        def enqueue; end
        private
        def run; end
      end
    RUBY

    test "without the plugin the conventional method is high-confidence dead" do
      candidate = candidates_for(SOURCE).find { |c| c.name == :run }

      assert_equal :high, candidate.confidence
      assert_empty candidate.reasons
    end

    test "the plugin downgrades it to :low but leaves it reported" do
      candidate = candidates_for(SOURCE, plugins: [SchedulerPlugin.new]).find { |c| c.name == :run }

      assert_equal :low, candidate.confidence
      assert_includes candidate.reasons, "invoked by the scheduler (convention)"
    end

    test "the gate holds: an unrelated class with a private run stays high" do
      candidate = candidates_for(<<~RUBY, plugins: [SchedulerPlugin.new]).find { |c| c.name == :run }
        class PlainObject
          def call; end
          private
          def run; end
        end
      RUBY

      assert_equal :high, candidate.confidence
      assert_empty candidate.reasons
    end
  end
end
