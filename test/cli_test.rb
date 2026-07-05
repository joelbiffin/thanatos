require 'test_helper'
require 'tempfile'
require 'stringio'

# The CLI's plugin loading: `--plugins FILE` requires the file(s), and the
# Thanatos::Plugin subclasses they define (registered on definition) are
# instantiated and applied to the run.
class CliTest < Minitest::Test
  def setup
    @tempfiles = []
  end

  def teardown
    @tempfiles.each(&:close!)
  end

  def write_ruby(source)
    file = Tempfile.new(["thanatos", ".rb"])
    @tempfiles << file
    file.write(source)
    file.flush
    file.path
  end

  TARGET = <<~RUBY
    class WidgetBase; end
    class MyWidget < WidgetBase
      on_widget :refresh
      def call; end
      private
      def refresh; end
    end
  RUBY

  LOADED_PLUGIN = <<~RUBY
    class LoadedWidgetPlugin < Thanatos::Plugin
      inherits_from "WidgetBase"
      reference_macro :on_widget, positional: "loaded via --plugins"
    end
  RUBY

  # Registered by being defined here, but never passed via --plugins.
  class UnloadedWidgetPlugin < Thanatos::Plugin
    inherits_from "WidgetBase"
    reference_macro :on_widget, positional: "should not appear"
  end

  test "--plugins loads a file and applies only the plugins it defines" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(TARGET), "--plugins", write_ruby(LOADED_PLUGIN)], out:)

    assert_includes out.string, "loaded via --plugins"       # the file we loaded
    refute_includes out.string, "should not appear"          # registered, but not loaded here
  end

  test "without --plugins no plugin runs" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(TARGET)], out:)

    refute_includes out.string, "loaded via --plugins"
    refute_includes out.string, "should not appear"
  end
end
