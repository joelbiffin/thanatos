class MyApp
  def trigger
    only_used_in_other_file
  end

  private

  def never_called
    :nope
  end
end
