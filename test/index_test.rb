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

  test "inherits_from? is true for a descendant of a named base" do
    assert @index.inherits_from?("Child", ["Base"])
  end

  test "inherits_from? matches through an included module" do
    assert @index.inherits_from?("Child", ["Greeting"])
  end

  test "inherits_from? is false for an unrelated class" do
    refute @index.inherits_from?("Base", ["Greeting"])
  end

  test "inherits_from? matches an out-of-scope base named only by an in-scope link" do
    index = index_for(<<~RUBY)
      class ApplicationController < ActionController::Base; end
      class PostsController < ApplicationController; end
    RUBY
    index.resolve_inheritance!

    assert index.inherits_from?("PostsController", ["ActionController::Base"])
  end

  # A node reachable by more than one path is collected once: the traversal
  # tracks what it has already visited. Without that, the shared ancestor
  # duplicates on a diamond and, on a cyclic include graph, the walk never ends.
  test "ancestors collect a diamond's shared ancestor exactly once" do
    index = index_for(<<~RUBY)
      module Top; end
      module Left;  include Top; end
      module Right; include Top; end

      class Bottom
        include Left
        include Right
      end
    RUBY
    index.resolve_inheritance!

    assert_equal ["Left", "Right", "Top"], index.ancestors("Bottom").map(&:fqn).sort
  end

  test "ancestors terminate on a cyclic include graph" do
    index = index_for(<<~RUBY)
      module A; include B; end
      module B; include A; end
    RUBY
    index.resolve_inheritance!

    assert_equal ["A", "B"], index.ancestors("A").map(&:fqn).sort
  end
end
