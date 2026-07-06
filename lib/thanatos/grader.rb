module Thanatos
  class Grader
    def initialize(signals:, hierarchy:, explicit_calls:, plugin_reasons:)
      @signals = signals
      @hierarchy = hierarchy
      @explicit_calls = explicit_calls
      @plugin_reasons = plugin_reasons
    end

    def grade(definition)
      reasons = @signals.reasons_for(definition)

      verdict, accounted_note = markers_verdict(definition)
      reasons << @signals.dynamic_dispatch_reason if verdict == :tainted

      if definition.visibility == :protected && @explicit_calls.include?(definition.name)
        reasons << "explicit call .#{definition.name} in the hierarchy (possible protected use)"
      end
      reasons.concat(@plugin_reasons[definition.name])

      confidence =
        if reasons.any?
          :low
        elsif verdict == :accounted_clean
          :medium
        else
          :high
        end
      reasons << accounted_note if confidence == :medium
      [confidence, reasons]
    end

    private

    def markers_verdict(definition)
      marker_classes = @hierarchy.select { |facts| facts.signals.dynamic_markers.any? }
      return [:none, nil] if marker_classes.empty?

      sources = []
      marker_classes.each do |marker_class|
        accounts = marker_class.dispatch_accounts
        return [:tainted, nil] if accounts.empty?
        return [:tainted, nil] if accounts.any? { |account| account.reaches?(definition.name) }

        sources.concat(accounts.map { |account| "#{account.source} (dispatch in #{marker_class.fqn})" })
      end
      [:accounted_clean, "dispatch accounted for by #{sources.uniq.join(', ')}"]
    end
  end
end
