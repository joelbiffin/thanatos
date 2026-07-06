module Thanatos
  class Candidate < Data.define(:fqn, :name, :visibility, :location, :confidence, :reasons)
    LEVELS = %i[low medium high].freeze

    def meets?(minimum)
      LEVELS.index(confidence) >= LEVELS.index(minimum)
    end

    def gating?
      confidence == LEVELS.last
    end
  end
end
