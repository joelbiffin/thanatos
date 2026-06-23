module Thanatos
  Candidate = Data.define(:fqn, :name, :visibility, :location, :confidence, :reasons) do
    def high_confidence?
      confidence == :high
    end
  end
end
