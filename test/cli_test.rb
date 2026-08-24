require 'test_helper'
require 'tempfile'
require 'stringio'

# The CLI's plugin loading: `--plugins FILE` requires the file(s), which are
# expected to register their plugins via Thanatos.configure. Only registered
# plugins are applied - defining a subclass does nothing on its own.
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
    Thanatos.configure { |config| config.register_plugin(LoadedWidgetPlugin) }
  RUBY

  # Defined here, but never registered via configure.
  class UnregisteredWidgetPlugin < Thanatos::Plugin
    inherits_from "WidgetBase"
    reference_macro :on_widget, positional: "should not appear"
  end

  test "--plugins applies the plugins its files register, and only those" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(TARGET), "--plugins", write_ruby(LOADED_PLUGIN)], out:)

    assert_includes out.string, "loaded via --plugins"       # registered by the loaded file
    refute_includes out.string, "should not appear"          # defined, but never registered
  end

  test "without --plugins no plugin runs" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(TARGET)], out:)

    refute_includes out.string, "loaded via --plugins"
    refute_includes out.string, "should not appear"
  end

  ACQUIT_PLUGIN = <<~RUBY
    class MachinePlugin < Thanatos::Plugin
      inherits_from "Machine"
      invokes :guarded, kwargs: %i[unless]
    end
    Thanatos.configure { |c| c.register_plugin(MachinePlugin) }
  RUBY

  ACQUIT_TARGET = <<~RUBY
    class Machine; end
    class Account < Machine
      guarded unless: :barable?
      def call; end
      private
      def barable?; end
    end
  RUBY

  test "--show-acquittals lists methods a plugin acquitted, with the count in the summary" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(ACQUIT_TARGET), "--plugins", write_ruby(ACQUIT_PLUGIN), "--show-acquittals"], out:)

    assert_includes out.string, "acquitted"
    assert_includes out.string, "barable?"
  end

  ACCOUNT_PLUGIN = <<~RUBY
    class SvcPlugin < Thanatos::Plugin
      inherits_from "Svc"
      accounts_for_dispatch reaches: :public
    end
    Thanatos.configure { |c| c.register_plugin(SvcPlugin) }
  RUBY

  ACCOUNT_TARGET = <<~RUBY
    module Svc
      def call(name); new.public_send(name); end
    end
    class Charge
      include Svc
      def call; end
      private
      def dead_helper; end
    end
  RUBY

  test "the summary itemises medium findings once a plugin accounts for a marker" do
    out = StringIO.new
    Thanatos::CLI.run([write_ruby(ACCOUNT_TARGET), "--plugins", write_ruby(ACCOUNT_PLUGIN)], out:)

    assert_match(/1 medium/, out.string)
  end
end
