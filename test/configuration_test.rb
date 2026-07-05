require 'test_helper'

# Registration is explicit: an app embeds Thanatos and opts its plugins in via
# Thanatos.configure. Defining a Thanatos::Plugin subclass does nothing on its
# own - only registering it does.
class ConfigurationTest < Minitest::Test
  class SamplePlugin < Thanatos::Plugin
    reference_macro :sample, positional: "via %{macro}"
  end

  test "defining a plugin subclass does not register it" do
    assert_empty Thanatos.configuration.plugins
  end

  test "configure registers a plugin class as an instance" do
    Thanatos.configure { |config| config.register_plugin(SamplePlugin) }

    assert_equal 1, Thanatos.configuration.plugins.length
    assert_instance_of SamplePlugin, Thanatos.configuration.plugins.first
  end

  test "register_plugin also accepts an already-built instance" do
    instance = SamplePlugin.new
    Thanatos.configure { |config| config.register_plugin(instance) }

    assert_same instance, Thanatos.configuration.plugins.first
  end

  test "reset! clears registered plugins" do
    Thanatos.configure { |config| config.register_plugin(SamplePlugin) }
    Thanatos.configuration.reset!

    assert_empty Thanatos.configuration.plugins
  end
end
