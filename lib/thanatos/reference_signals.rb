module Thanatos
  class ReferenceSignals
    attr_reader :symbol_literals, :dynamic_markers, :call_sites

    def initialize
      @symbol_literals = Set.new
      @dynamic_markers = Set.new
      @call_sites = []
    end

    def record_symbol_literal(name)
      @symbol_literals << name
    end

    def record_dynamic_marker(name)
      @dynamic_markers << name
    end

    def record_call_site(name:, positional:, kwargs:)
      @call_sites << CallSite.new(name:, positional:, kwargs:)
    end

    def merge(other)
      @symbol_literals.merge(other.symbol_literals)
      @dynamic_markers.merge(other.dynamic_markers)
      @call_sites.concat(other.call_sites)
      self
    end

    def reasons_for(definition)
      reasons = []

      if @symbol_literals.include?(definition.name)
        reasons << "referenced as symbol literal :#{definition.name} (callback/delegate/send?)"
      end

      if @dynamic_markers.any?
        reasons << "class uses dynamic dispatch (#{@dynamic_markers.sort.join(', ')})"
      end

      reasons
    end
  end
end
