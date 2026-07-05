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

    InvokeSpec = Data.define(:name, :positional, :kwargs) do
      def invocations(site)
        invoked = []
        invoked.concat(site.positional) if positional
        site.kwargs.each { |key, symbols| invoked.concat(symbols) if kwargs.include?(key) }
        invoked.map { |symbol| [symbol, name] }
      end
    end

    class << self
      def inherits_from(*names)
        @base_names = base_names + names.map { |name| name.to_s.delete_prefix("::") }
      end

      def invokes(*names, positional: true, kwargs: [])
        specs = names.to_h do |name|
          [name.to_sym, InvokeSpec.new(name: name.to_sym, positional:, kwargs: kwargs.map(&:to_sym))]
        end
        @invoke_specs = invoke_specs.merge(specs)
      end

      def invoke_specs
        @invoke_specs || {}
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
        facts.signals.call_sites.select { |site| site.name == spec.name }.flat_map { |site| spec.reasons(site) }
      end
    end

    def invocations_for_class(facts)
      self.class.invoke_specs.each_value.flat_map do |spec|
        facts.signals.call_sites.select { |site| site.name == spec.name }.flat_map { |site| spec.invocations(site) }
      end
    end
  end
end
