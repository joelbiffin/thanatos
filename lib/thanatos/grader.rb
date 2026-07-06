module Thanatos
  class Grader
    Verdict = Data.define(:confidence, :reasons)

    MarkerResolution = Data.define(:state, :accounts) do
      def self.none = new(state: :none, accounts: [])
      def self.tainted = new(state: :tainted, accounts: [])
      def self.accounted(accounts) = new(state: :accounted_clean, accounts:)

      def tainted? = state == :tainted
      def accounted_clean? = state == :accounted_clean

      def provenance
        "dispatch accounted for by #{accounts.map { |source, fqn| "#{source} (dispatch in #{fqn})" }.uniq.join(', ')}"
      end
    end

    def initialize(signals:, hierarchy:, explicit_calls:, plugin_reasons:)
      @signals = signals
      @hierarchy = hierarchy
      @explicit_calls = explicit_calls
      @plugin_reasons = plugin_reasons
    end

    def grade(definition)
      markers = resolve_markers(definition)
      doubts = doubt_reasons(definition, markers)

      return Verdict.new(confidence: :low, reasons: doubts) if doubts.any?
      return Verdict.new(confidence: :medium, reasons: [markers.provenance]) if markers.accounted_clean?

      Verdict.new(confidence: :high, reasons: [])
    end

    private

    def doubt_reasons(definition, markers)
      reasons = @signals.reasons_for(definition)
      reasons << @signals.dynamic_dispatch_reason if markers.tainted?
      if definition.visibility == :protected && @explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} in the hierarchy (possible protected use)"
      end
      reasons.concat(@plugin_reasons[definition.name])
    end

    def resolve_markers(definition)
      marker_classes = @hierarchy.select { |facts| facts.signals.dynamic_markers.any? }
      return MarkerResolution.none if marker_classes.empty?

      accounts = []
      marker_classes.each do |marker_class|
        class_accounts = marker_class.dispatch_accounts
        return MarkerResolution.tainted if class_accounts.empty?
        return MarkerResolution.tainted if class_accounts.any? { |account| account.reaches?(definition.name) }

        class_accounts.each { |account| accounts << [account.source, marker_class.fqn] }
      end
      MarkerResolution.accounted(accounts)
    end
  end
end
