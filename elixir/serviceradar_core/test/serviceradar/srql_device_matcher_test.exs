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

  test "apply_filters supports op aliases and custom field mappings" do
    query = Ash.Query.new(ServiceRadar.Inventory.Device)

    filters = [
      %{field: "type", op: "equals", value: 3},
      %{field: "hostname", op: "like", value: "%router%"}
    ]

    filtered =
      SRQLDeviceMatcher.apply_filters(query, filters,
        field_mappings: %{"type" => :type_id, "hostname" => :hostname},
        allow_existing_atom_fields?: false,
        tag_fields?: false
      )

    assert %Ash.Query{} = filtered
  end

  test "apply_filters skips unknown fields when existing atoms are disabled" do
    query = Ash.Query.new(ServiceRadar.Inventory.Device)
    filters = [%{field: "does_not_exist", op: "eq", value: "x"}]

    assert %Ash.Query{} =
             SRQLDeviceMatcher.apply_filters(query, filters,
               field_mappings: %{},
               allow_existing_atom_fields?: false
             )
  end
end
