class Template
  def render
    body
  end

  private

  def body
    raise NotImplementedError
  end
end

class HtmlTemplate < Template
  private

  def body
    "<html></html>"
  end
end
