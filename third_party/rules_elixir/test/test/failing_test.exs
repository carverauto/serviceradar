ExUnit.start(trace: true)

defmodule AssertionTest do
  use ExUnit.Case, async: true

  test "the truth" do
    assert false
  end
end
