module Thanatos
  class Plugin
    MacroSpec = Data.define(:name, :positional, :kwargs, :default_kwarg) do
      def reasons(site)
        reasons = []

        if positional
          site.positional.each { |symbol| reasons << [symbol, positional % { macro: name }] }
        end

        site.kwargs.each do |key, symbols|
          template = kwargs.fetch(key, default_kwarg)
          next unless template

          symbols.each { |symbol| reasons << [symbol, template % { macro: name, key: key }] }
        end

        reasons
      end
    end

    class << self
      def inherits_from(*names)
        @base_names = base_names + names.map { |name| name.to_s.delete_prefix("::") }
      end

      def base_names
        @base_names || []
      end

      def reference_macro(*names, positional: nil, kwargs: {}, default_kwarg: nil)
        specs = names.to_h do |name|
          [name.to_sym, MacroSpec.new(name: name.to_sym, positional:, kwargs: kwargs.transform_keys(&:to_sym), default_kwarg:)]
        end
        @macros = macros.merge(specs)
      end

      def macros
        @macros || {}
      end
    end

    def applies_to?(index, fqn)
      bases = self.class.base_names
      return true if bases.empty?

      index.inherits_from?(fqn, bases)
    end

    def reasons_for_class(facts)
      self.class.macros.each_value.flat_map do |spec|
        facts.call_sites.select { |site| site.name == spec.name }.flat_map { |site| spec.reasons(site) }
      end
    end
  end
end
