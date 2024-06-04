class Base
  def foo
    bar
  end

  private

  # This is probably optional
  def bar
    raise NotImplementedError
  end
end

class Thing < Base
  private

  def bar
    'hello!'
  end
end