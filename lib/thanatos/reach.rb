module Thanatos
  class Reach
    def initialize(spec)
      @matcher =
        case spec
        when :public, :none then ->(_name) { false }
        when Regexp then ->(name) { spec.match?(name.to_s) }
        when Array, Set then names = spec.map(&:to_sym).to_set; ->(name) { names.include?(name) }
        else raise ArgumentError, "unsupported dispatch reach: #{spec.inspect} " \
                                   "(expected :public, :none, a Regexp, or a list of method names)"
        end
    end

    def reaches?(name)
      @matcher.call(name)
    end
  end

  DispatchAccount = Data.define(:reach, :source) do
    def reaches?(name)
      reach.reaches?(name)
    end
  end
end
