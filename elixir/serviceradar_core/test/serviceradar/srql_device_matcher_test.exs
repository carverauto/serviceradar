defmodule ServiceRadar.SRQLDeviceMatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SRQLDeviceMatcher

  test "extract_filters normalizes SRQL ast filters" do
    ast = %{
      "filters" => [
        %{"field" => "hostname", "value" => "router-1"},
        %{"field" => "tags.role", "op" => "contains", "value" => "network"}
      ]
    }

    assert SRQLDeviceMatcher.extract_filters(ast) == [
             %{field: "hostname", op: "eq", value: "router-1"},
             %{field: "tags.role", op: "contains", value: "network"}
           ]
  end

  test "extract_filters returns an empty list when the ast has no filters" do
    assert SRQLDeviceMatcher.extract_filters(%{}) == []
  end
end
