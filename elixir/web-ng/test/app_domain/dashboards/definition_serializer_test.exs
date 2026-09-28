defmodule ServiceRadarWebNG.Dashboards.DefinitionSerializerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.DefinitionSerializer

  @moduletag :db_free

  defp panel(overrides \\ %{}) do
    Map.merge(
      %{
        id: 99,
        dashboard_id: 1,
        title: "Panel A",
        srql_query: "in:devices limit:10",
        visual_type: :table,
        data_binding: %{"label_field" => "name"},
        display_config: %{"show_header" => true},
        visual_config: %{"colors" => []},
        layout: %{"x" => 0, "y" => 0, "w" => 12, "h" => 4},
        position: 0,
        inserted_at: ~U[2024-01-01 00:00:00Z],
        updated_at: ~U[2024-01-01 00:00:00Z],
        builder_state: %{"some" => "state"},
        field_metadata: %{"name" => %{"type" => "text"}},
        dataset_key: "devices",
        refresh_interval_seconds: 30,
        metadata: %{"extra" => "hint"}
      },
      overrides
    )
  end

  defp dashboard(overrides \\ %{}) do
    Map.merge(
      %{
        id: 42,
        dashboard_ref: 7,
        slug: "my-dashboard",
        title: "My Dashboard",
        description: "A test dashboard",
        default_time_range: "last_1h",
        metadata: %{"theme" => "dark"},
        variables: %{"env" => "prod"},
        inserted_at: ~U[2024-01-01 00:00:00Z],
        updated_at: ~U[2024-01-01 00:00:00Z],
        archived_at: nil,
        owner_id: 123,
        visibility: :private,
        status: :active,
        panels: []
      },
      overrides
    )
  end

  describe "version" do
    test "emits version 1" do
      result = DefinitionSerializer.serialize(dashboard())
      assert result["version"] == 1
    end
  end

  describe "dashboard fields" do
    test "includes slug, title, description, default_time_range" do
      result = DefinitionSerializer.serialize(dashboard())
      assert result["slug"] == "my-dashboard"
      assert result["title"] == "My Dashboard"
      assert result["description"] == "A test dashboard"
      assert result["default_time_range"] == "last_1h"
    end

    test "includes metadata map from dashboard" do
      result = DefinitionSerializer.serialize(dashboard(%{metadata: %{"theme" => "dark"}}))
      assert result["metadata"] == %{"theme" => "dark"}
    end

    test "defaults metadata to empty map when nil" do
      result = DefinitionSerializer.serialize(dashboard(%{metadata: nil}))
      assert result["metadata"] == %{}
    end

    test "includes variables map from dashboard" do
      result = DefinitionSerializer.serialize(dashboard(%{variables: %{"env" => "prod"}}))
      assert result["variables"] == %{"env" => "prod"}
    end

    test "defaults variables to empty map when nil" do
      result = DefinitionSerializer.serialize(dashboard(%{variables: nil}))
      assert result["variables"] == %{}
    end
  end

  describe "excluded dashboard fields" do
    test "does not include id" do
      result = DefinitionSerializer.serialize(dashboard())
      refute Map.has_key?(result, "id")
    end

    test "does not include dashboard_ref" do
      result = DefinitionSerializer.serialize(dashboard())
      refute Map.has_key?(result, "dashboard_ref")
    end

    test "does not include inserted_at, updated_at, archived_at" do
      result = DefinitionSerializer.serialize(dashboard())
      refute Map.has_key?(result, "inserted_at")
      refute Map.has_key?(result, "updated_at")
      refute Map.has_key?(result, "archived_at")
    end

    test "does not include owner_id" do
      result = DefinitionSerializer.serialize(dashboard())
      refute Map.has_key?(result, "owner_id")
    end

    test "does not include visibility or status" do
      result = DefinitionSerializer.serialize(dashboard())
      refute Map.has_key?(result, "visibility")
      refute Map.has_key?(result, "status")
    end
  end

  describe "panels" do
    test "emits an empty panels list when no panels" do
      result = DefinitionSerializer.serialize(dashboard(%{panels: []}))
      assert result["panels"] == []
    end

    test "serializes a single panel with expected fields" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]

      assert p["title"] == "Panel A"
      assert p["srql_query"] == "in:devices limit:10"
      assert p["visual_type"] == "table"
      assert p["data_binding"] == %{"label_field" => "name"}
      assert p["display_config"] == %{"show_header" => true}
      assert p["visual_config"] == %{"colors" => []}
      assert p["layout"] == %{"x" => 0, "y" => 0, "w" => 12, "h" => 4}
      assert p["position"] == 0
    end

    test "sorts panels by position ascending" do
      panels = [
        panel(%{title: "Third", position: 2}),
        panel(%{title: "First", position: 0}),
        panel(%{title: "Second", position: 1})
      ]

      result = DefinitionSerializer.serialize(dashboard(%{panels: panels}))

      titles = Enum.map(result["panels"], & &1["title"])
      assert titles == ["First", "Second", "Third"]
    end

    test "visual_type is serialized as a string" do
      d = dashboard(%{panels: [panel(%{visual_type: :bar})]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      assert p["visual_type"] == "bar"
    end

    test "panel data_binding defaults to empty map when nil" do
      d = dashboard(%{panels: [panel(%{data_binding: nil})]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      assert p["data_binding"] == %{}
    end

    test "panel display_config defaults to empty map when nil" do
      d = dashboard(%{panels: [panel(%{display_config: nil})]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      assert p["display_config"] == %{}
    end

    test "panel visual_config defaults to empty map when nil" do
      d = dashboard(%{panels: [panel(%{visual_config: nil})]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      assert p["visual_config"] == %{}
    end

    test "panel position falls back to index when nil" do
      d = dashboard(%{panels: [panel(%{position: nil})]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      assert p["position"] == 0
    end
  end

  describe "excluded panel fields" do
    test "does not include id, dashboard_id" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "id")
      refute Map.has_key?(p, "dashboard_id")
    end

    test "does not include inserted_at or updated_at" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "inserted_at")
      refute Map.has_key?(p, "updated_at")
    end

    test "does not include builder_state" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "builder_state")
    end

    test "does not include field_metadata" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "field_metadata")
    end

    test "does not include dataset_key" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "dataset_key")
    end

    test "does not include refresh_interval_seconds or metadata" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      [p] = result["panels"]
      refute Map.has_key?(p, "refresh_interval_seconds")
      refute Map.has_key?(p, "metadata")
    end
  end

  describe "JSON roundtrip" do
    test "serialize output encodes and decodes cleanly via Jason" do
      d = dashboard(%{panels: [panel()]})
      result = DefinitionSerializer.serialize(d)
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert decoded["version"] == 1
      assert decoded["slug"] == "my-dashboard"
      assert length(decoded["panels"]) == 1
    end
  end
end
