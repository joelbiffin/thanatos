require 'test_helper'

# LocalVariables is a separate lexical pass: per scope, a variable assigned but
# never read is dead. These pin its rules in isolation - including the ones that
# keep it sound (closures count as use, eval/binding force abstention) and quiet
# (underscore-prefixed names are intentional).
class LocalVariablesTest < Minitest::Test
  def locals(source)
    program = Prism.parse(source).value
    Thanatos::LocalVariables.new(file: "(inline)").candidates(program).map(&:name)
  end

  def test_assigned_but_unread_local_is_reported
    assert_equal [:unused], locals(<<~RUBY)
      class Foo
        def call
          unused = compute
          42
        end
      end
    RUBY
  end

  def test_a_local_that_is_read_is_not_reported
    assert_empty locals(<<~RUBY)
      class Foo
        def call
          value = compute
          value + 1
        end
      end
    RUBY
  end

  # `depth` resolves a closure's read to the outer scope that owns the variable.
  def test_a_read_inside_a_closure_counts_as_use
    assert_empty locals(<<~RUBY)
      class Foo
        def call
          total = 0
          [1, 2].each { |n| total += n }
          total
        end
      end
    RUBY
  end

  def test_underscore_prefixed_names_are_ignored
    assert_empty locals(<<~RUBY)
      class Foo
        def call
          _ignored = compute
          42
        end
      end
    RUBY
  end

  # eval/binding could read a local by a name we cannot see, so we abstain.
  def test_abstains_in_a_scope_that_uses_binding
    assert_empty locals(<<~RUBY)
      class Foo
        def call
          unused = compute
          binding
        end
      end
    RUBY
  end
end
