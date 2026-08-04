ExUnit.configure(
  seed: 0
)

ExUnit.start(trace: true)

defmodule TestHelper do
  def the_truth do
    true
  end
end
