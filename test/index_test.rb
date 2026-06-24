require 'test_helper'

# Index owns the inheritance graph. Reachability leans on it to span the right
# set of classes, so these check the graph directly: ancestry through superclass
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

  def test_resolves_a_superclass_to_its_fully_qualified_name
    assert_equal "Base", @index["Child"].superclass_fqn
  end

  def test_ancestors_span_the_superclass_chain_and_included_modules
    assert_equal ["Base", "Greeting"], @index.ancestors("Child").map(&:fqn).sort
  end

  def test_descendants_cover_both_subclasses_and_includers
    assert_includes @index.descendants("Base").map(&:fqn), "Child"      # subclass
    assert_includes @index.descendants("Greeting").map(&:fqn), "Child"  # includer
  end

  def test_extenders_lists_the_classes_that_extend_a_module
    # `extend self` makes Toolkit an extender of itself.
    assert_includes @index.extenders("Toolkit").map(&:fqn), "Toolkit"
  end
end
