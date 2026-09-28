defmodule ServiceRadarWebNG.Dashboards.DashboardExportRoundTripDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.DefinitionSerializer
  alias ServiceRadarWebNG.Dashboards.SystemReports

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  setup do
    marker = "sr-rtrip-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup!(marker) end)
    actor = SystemActor.system(:export_round_trip_test)
    %{actor: actor, marker: marker}
  end

  @tag :web_ng_shared_fixture_db
  test "export/import round trip preserves all format-defined fields", %{
    actor: actor,
    marker: marker
  } do
    source_slug = "#{marker}-source"
    import_slug = "#{marker}-imported"

    {:ok, source} =
      AuthoredDashboard
      |> Ash.Changeset.for_create(:create, %{
        dashboard_ref: synthetic_ref(),
        title: "Round-trip source #{marker}",
        description: "A dashboard for export testing",
        slug: source_slug,
        visibility: :private,
        status: :active,
        default_time_range: "last_24h",
        metadata: %{"test_marker" => marker},
        variables: %{"env" => "test"}
      })
      |> Ash.create(actor: actor)

    panels = [
      %{
        title: "Hop loss by position",
        srql_query: ~s|stats:"loss_ratio(sent, received) as loss by hop_number" in:mtr_hops sort:hop_number limit:20|,
        visual_type: :bar,
        data_binding: %{"label_field" => "hop_number", "value_field" => "loss"},
        display_config: %{"caption" => "Loss by hop"},
        visual_config: %{},
        layout: %{"x" => 0, "y" => 0, "w" => 6, "h" => 4},
        position: 0
      },
      %{
        title: "Reach rate per target",
        srql_query: ~s|stats:"avg(target_reached) as reach by target_ip" in:mtr_traces sort:reach:desc limit:10|,
        visual_type: :table,
        data_binding: %{},
        display_config: %{},
        visual_config: %{"show_sparkline" => false},
        layout: %{"x" => 6, "y" => 0, "w" => 6, "h" => 4},
        position: 1
      },
      %{
        title: "Loss trend",
        srql_query: ~s|stats:"loss_ratio(sent, received) as loss by time:1h" in:mtr_hops sort:bucket limit:48|,
        visual_type: :line,
        data_binding: %{"time_field" => "bucket", "value_field" => "loss"},
        display_config: %{},
        visual_config: %{},
        layout: %{"x" => 0, "y" => 4, "w" => 12, "h" => 4},
        position: 2
      }
    ]

    for panel_attrs <- panels do
      {:ok, _} =
        DashboardPanel
        |> Ash.Changeset.for_create(:create, Map.put(panel_attrs, :dashboard_id, source.id))
        |> Ash.create(actor: actor)
    end

    {:ok, source_with_panels} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: source_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert length(source_with_panels.panels) == length(panels)

    # Export
    definition_map = DefinitionSerializer.serialize(source_with_panels)

    assert definition_map["version"] == 1
    assert definition_map["slug"] == source_slug
    assert definition_map["title"] == source_with_panels.title
    assert definition_map["description"] == source_with_panels.description
    assert definition_map["default_time_range"] == source_with_panels.default_time_range
    assert definition_map["metadata"] == source_with_panels.metadata
    assert definition_map["variables"] == source_with_panels.variables
    assert length(definition_map["panels"]) == length(panels)

    # Rewrite slug for a clean import (simulates another installation or a copy)
    import_map = Map.put(definition_map, "slug", import_slug)

    {:ok, spec} = Definition.validate(import_map, "round-trip-test")

    # Import
    {:ok, _imported} = SystemReports.ensure_dashboard(actor, spec)

    {:ok, imported} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: import_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert imported, "imported dashboard must exist"
    assert imported.slug == import_slug
    assert imported.title == source_with_panels.title
    assert imported.description == source_with_panels.description
    assert imported.default_time_range == source_with_panels.default_time_range
    assert imported.metadata == source_with_panels.metadata
    assert imported.variables == source_with_panels.variables

    # Panel equivalence: same set of panels over all format-defined fields
    assert length(imported.panels) == length(panels),
           "imported dashboard must have #{length(panels)} panels, got #{length(imported.panels)}"

    source_panels = Enum.sort_by(source_with_panels.panels, & &1.position)
    imported_panels = Enum.sort_by(imported.panels, & &1.position)

    for {src, imp} <- Enum.zip(source_panels, imported_panels) do
      assert imp.title == src.title
      assert imp.srql_query == src.srql_query
      assert imp.visual_type == src.visual_type
      assert imp.data_binding == src.data_binding
      assert imp.display_config == src.display_config
      assert imp.visual_config == src.visual_config
      assert imp.layout == src.layout
      assert imp.position == src.position
    end

    # Excluded fields: the import must assign its own identity (different ids)
    refute imported.id == source.id
    refute imported.dashboard_ref == source.dashboard_ref
  end

  defp synthetic_ref do
    1_000_000 + :erlang.phash2(Ecto.UUID.generate(), 9_000_000)
  end

  defp cleanup!(marker) do
    slug_pattern = "#{marker}-%"

    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: like(d.slug, ^slug_pattern)
      )
    )
  end
end
