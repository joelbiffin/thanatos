class Foo
  def bar
    baz
  end

  private

  def baz
    "calling baz"
  end
end

class Qux
  def bar
    baz
  end

  def baz
    "calling baz"
  end

  private

  def baq
    "do something else"
  end
end