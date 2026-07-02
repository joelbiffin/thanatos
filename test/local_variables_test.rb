require 'test_helper'

# LocalVariables is a separate lexical pass: per scope, a variable assigned but
# never read is dead. These pin the rules that keep it sound (closures count as
# use, eval/binding force abstention) and quiet (underscore names are intentional).
class LocalVariablesTest < Minitest::Test
  def locals(source)
    program = Prism.parse(source).value
    Thanatos::LocalVariables.new(file: "(inline)").candidates(program).map(&:name)
  end

  test "an assigned but unread local is reported" do
    assert_equal [:unused], locals(<<~RUBY)
      class Foo
        def call
          unused = compute
          42
        end
      end
    RUBY
  end

  test "a local that is read is not reported" do
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
  test "a read inside a closure counts as use" do
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

  test "underscore-prefixed names are ignored" do
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
  test "abstains in a scope that uses binding" do
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
