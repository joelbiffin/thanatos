class MixedConfidence
  before_action :guarded

  private

  def guarded
    "downgraded to low confidence by the :guarded symbol literal"
  end

  def orphaned
    "genuinely dead - high confidence"
  end
end
