module Thanatos
  class Reach
    def initialize(spec)
      @spec = spec
    end

    def reaches?(name)
      case @spec
      when Regexp then @spec.match?(name.to_s)
      when Array, Set then @spec.include?(name)
      else false
      end
    end
  end

  DispatchAccount = Data.define(:reach, :source) do
    def reaches?(name)
      reach.reaches?(name)
    end
  end
end
