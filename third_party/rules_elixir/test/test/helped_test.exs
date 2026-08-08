defmodule AssertionTest do
  use ExUnit.Case, async: true
  import TestHelper

  test "the truth" do
    assert the_truth()
  end
end
