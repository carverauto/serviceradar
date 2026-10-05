defmodule ServiceRadar.SRQLDeviceMatcherTest do
  use ExUnit.Case, async: true

  alias Ash.Filter.Runtime
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
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

  test "filters_supported? accepts matcher-supported filters and rejects ignored ones" do
    assert SRQLDeviceMatcher.filters_supported?(%{
             "filters" => [
               %{"field" => "hostname", "op" => "contains", "value" => "router"},
               %{"field" => "is_active", "op" => "neq", "value" => "false"},
               %{"field" => "tags.role", "value" => "network"}
             ]
           })

    refute SRQLDeviceMatcher.filters_supported?(%{
             "filters" => [%{"field" => "unsupported_field", "value" => "x"}]
           })

    refute SRQLDeviceMatcher.filters_supported?(%{
             "filters" => [%{"field" => "hostname", "op" => "unsupported", "value" => "x"}]
           })

    refute SRQLDeviceMatcher.filters_supported?(%{
             "filters" => [%{"field" => "include_inactive", "value" => "perhaps"}]
           })
  end

  test "apply_filters supports op aliases and custom field mappings" do
    query = Ash.Query.new(Device)

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
    query = Ash.Query.new(Device)
    filters = [%{field: "does_not_exist", op: "eq", value: "x"}]

    assert %Ash.Query{} =
             SRQLDeviceMatcher.apply_filters(query, filters,
               field_mappings: %{},
               allow_existing_atom_fields?: false
             )
  end

  test "include_inactive is accepted as a device matcher control filter" do
    query = Ash.Query.new(Device)
    filters = [%{field: "include_inactive", op: "eq", value: "true"}]

    assert %Ash.Query{} = SRQLDeviceMatcher.apply_filters(query, filters)
  end

  describe "source_retired records" do
    test "are hidden unless the query asks for them" do
      assert matching_uids([]) == ["unmarked"]
      assert matching_uids([filter("include_retired", "eq", "false")]) == ["unmarked"]
      assert matching_uids([filter("include_retired", "eq", "true")]) == ["marked", "unmarked"]
      assert matching_uids([filter("include_retired", "eq", true)]) == ["marked", "unmarked"]
    end

    test "a source_retired filter replaces the default" do
      assert matching_uids([filter("source_retired", "eq", "true")]) == ["marked"]
      assert matching_uids([filter("source_retired", "eq", "false")]) == ["unmarked"]
      assert matching_uids([filter("source_retired", "neq", "true")]) == ["unmarked"]
      assert matching_uids([filter("source_retired", "not_equals", "false")]) == ["marked"]
      assert matching_uids([filter("SOURCE_RETIRED", "equals", true)]) == ["marked"]
    end

    test "a source_retired filter the matcher skips keeps the default" do
      assert matching_uids([filter("source_retired", "eq", "perhaps")]) == ["unmarked"]
      assert matching_uids([filter("source_retired", "contains", "true")]) == ["unmarked"]
    end

    test "the controls are supported filters only in their supported forms" do
      assert SRQLDeviceMatcher.filters_supported?(%{
               "filters" => [
                 %{"field" => "include_retired", "op" => "eq", "value" => "true"},
                 %{"field" => "source_retired", "op" => "neq", "value" => "false"}
               ]
             })

      for unsupported <- [
            %{"field" => "include_retired", "op" => "neq", "value" => "true"},
            %{"field" => "include_retired", "value" => "perhaps"},
            %{"field" => "source_retired", "value" => "perhaps"},
            %{"field" => "source_retired", "op" => "in", "value" => ["true"]}
          ] do
        refute SRQLDeviceMatcher.filters_supported?(%{"filters" => [unsupported]}),
               inspect(unsupported)
      end
    end

    test "do not filter a query on another resource" do
      for filters <- [[], [filter("source_retired", "eq", "true")]] do
        assert %Ash.Query{filter: nil, errors: []} =
                 SRQLDeviceMatcher.apply_filters(Ash.Query.new(Interface), filters,
                   allow_existing_atom_fields?: false,
                   tag_fields?: false,
                   default_active?: false
                 )
      end
    end
  end

  defp filter(field, op, value), do: %{field: field, op: op, value: value}

  # Evaluates the matcher's filter in memory against one marked and one unmarked record.
  defp matching_uids(filters) do
    records = [
      %Device{uid: "marked", is_active: true, source_retired_at: ~U[2026-01-02 03:04:05.000000Z]},
      %Device{uid: "unmarked", is_active: true, source_retired_at: nil}
    ]

    query = SRQLDeviceMatcher.apply_filters(Ash.Query.new(Device), filters)
    assert query.errors == []

    {:ok, matches} = Runtime.filter_matches(ServiceRadar.Inventory, records, query.filter)
    matches |> Enum.map(& &1.uid) |> Enum.sort()
  end
end
