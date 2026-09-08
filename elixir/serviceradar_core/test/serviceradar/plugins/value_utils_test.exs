defmodule ServiceRadar.Plugins.ValueUtilsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ValueUtils

  test "raw_value preserves false values" do
    assert ValueUtils.raw_value(%{enabled: false}, [:enabled, "enabled"]) == false
    assert ValueUtils.bool_value(%{enabled: false}, [:enabled, "enabled"], true) == false
  end
end
