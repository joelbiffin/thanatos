class Base
  def perform
    setup
  end

  private

  def setup
    "ready"
  end

  def orphan
    "never referenced anywhere"
  end
end

class Worker < Base
  def run
    setup
  end
end
