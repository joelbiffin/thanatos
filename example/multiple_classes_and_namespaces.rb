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

  module Baz
    class Bar
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
    end
  end

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
end
