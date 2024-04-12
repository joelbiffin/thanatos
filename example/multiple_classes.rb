class Foo
  def bar
    baz
  end

  def baz
    "calling baz"
  end

  def baq
    "do something else"
  end
end

# just a copy
class Qux
  def bar
    baz
  end

  def baz
    "calling baz"
  end

  def baq
    "do something else"
  end
end
