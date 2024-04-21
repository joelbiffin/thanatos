# ProgramNode
# |-- StatementsNode
# |---|-- ClassNode (class_keyword_loc: "class", name: :Foo)
# |---|---|   constant_path: ConstantReadNode (name: :Foo)
class Foo
# |---|---|-- StatementsNode
# |---|---|---|-- DefNode (name: :bar)
# |---|---|---|---|   receiver: SelfNode
  def self.bar
# |---|---|---|---|-- StatementsNode
# |---|---|---|---|---|-- CallNode (name: :baz)
    baz
  end

# |---|---|---|-- DefNode (name: :baz)
# |---|---|---|---|   receiver: SelfNode
  def self.baz
# |---|---|---|---|-- StatementsNode
# |---|---|---|---|---|-- StringNode
    "calling baz"
  end

# |---|---|---|-- SingletonClassNode
# |---|---|---|---|   expression: SelfNode
  class << self
# |---|---|---|---|-- StatementsNode
# |---|---|---|---|---|-- DefNode (name: :baq)
# |---|---|---|---|---|---|   receiver: nil
    def baq
# |---|---|---|---|---|---|-- StatementsNode
# |---|---|---|---|---|---|---!-- StringNode
      "do something else"
    end
  end

# |---|---|---|-- DefNode (name: :baz)
# |---|---|---|---|   receiver: nil
  def bar
    "calling instance bar"
  end
end
