require 'test_helper'

# Index owns the inheritance graph Reachability spans: ancestry through superclass
# AND includes, the inverse (descendants), and the extend relation.
class IndexTest < Minitest::Test
  def setup
    @index = index_for(<<~RUBY)
      module Greeting; end

      class Base; end

      class Child < Base
        include Greeting
      end

      module Toolkit
        extend self
      end
    RUBY
    @index.resolve_inheritance!
  end

  test "resolves a superclass to its fully-qualified name" do
    assert_equal "Base", @index["Child"].superclass_fqn
  end

  test "ancestors span the superclass chain and included modules" do
    assert_equal ["Base", "Greeting"], @index.ancestors("Child").map(&:fqn).sort
  end

  test "descendants cover both subclasses and includers" do
    assert_includes @index.descendants("Base").map(&:fqn), "Child"      # subclass
    assert_includes @index.descendants("Greeting").map(&:fqn), "Child"  # includer
  end

  test "extenders lists the classes that extend a module" do
    assert_includes @index.extenders("Toolkit").map(&:fqn), "Toolkit"   # extend self
  end
end
