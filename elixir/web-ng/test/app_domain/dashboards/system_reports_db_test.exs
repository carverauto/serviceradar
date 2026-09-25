defmodule ServiceRadarWebNG.Dashboards.SystemReportsDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Dashboards.SystemReports

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  setup do
    marker = "sr-import-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup!(marker) end)
    actor = SystemActor.system(:system_reports_db_test)
    %{actor: actor, marker: marker}
  end

  @tag :web_ng_shared_fixture_db
  test "creates both built-in dashboards when absent", %{actor: actor} do
    assert {:ok, dashboards} = SystemReports.seed_all(actor: actor)

    slugs = Enum.map(dashboards, & &1.slug)
    assert SystemReports.new_devices_slug() in slugs
    assert SystemReports.mtr_path_analytics_slug() in slugs

    for spec <- SystemReports.dashboard_specs() do
      dashboard = Enum.find(dashboards, &(&1.slug == spec.slug))
      assert dashboard, "seed_all must return a dashboard for slug #{spec.slug}"

      {:ok, loaded} =
        AuthoredDashboard
        |> Ash.Query.for_read(:by_slug, %{slug: spec.slug})
        |> Ash.Query.load([:panels])
        |> Ash.read_one(actor: actor)

      assert loaded, "slug #{spec.slug} must exist in the database after seed_all"

      assert length(loaded.panels) == length(spec.panels),
             "#{spec.slug} must have #{length(spec.panels)} panel(s), got #{length(loaded.panels)}"
    end
  end

  @tag :web_ng_shared_fixture_db
  test "does not overwrite an existing dashboard on reseed", %{actor: actor, marker: marker} do
    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    mtr_slug = SystemReports.mtr_path_analytics_slug()

    {:ok, mtr} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    panel = hd(mtr.panels)
    edited_query = "in:mtr_hops addr:#{marker} limit:5"

    Repo.update_all(
      from(p in "dashboard_panels", prefix: "platform", where: p.id == ^Ecto.UUID.dump!(panel.id)),
      set: [srql_query: edited_query]
    )

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_reseed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    saved = Enum.find(after_reseed.panels, &(&1.id == panel.id))
    assert saved.srql_query == edited_query, "reseed must not overwrite an operator-edited panel query"
  end

  @tag :web_ng_shared_fixture_db
  test "does not remove an operator-added panel on reseed", %{actor: actor} do
    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    mtr_slug = SystemReports.mtr_path_analytics_slug()

    {:ok, mtr} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    {:ok, added} =
      DashboardPanel
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: mtr.id,
        title: "Operator panel",
        srql_query: "in:mtr_hops limit:1",
        visual_type: :table,
        data_binding: %{},
        layout: %{"x" => 0, "y" => 20, "w" => 12, "h" => 4},
        position: 99
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_reseed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    panel_ids = Enum.map(after_reseed.panels, & &1.id)
    assert added.id in panel_ids, "reseed must not remove a panel the operator added"
  end

  @tag :web_ng_shared_fixture_db
  test "completes a dashboard that exists with no panels", %{actor: actor} do
    new_devices_slug = SystemReports.new_devices_slug()

    {:ok, empty_dashboard} =
      AuthoredDashboard
      |> Ash.Changeset.for_create(:create, %{
        dashboard_ref: Enum.random(1_000_000..9_999_999),
        title: "New devices",
        slug: new_devices_slug,
        visibility: :public,
        status: :active
      })
      |> Ash.create(actor: actor)

    {:ok, loaded_empty} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: new_devices_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert loaded_empty.panels == [], "precondition: dashboard exists with no panels"

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_seed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: new_devices_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    expected_spec = Enum.find(SystemReports.dashboard_specs(), &(&1.slug == new_devices_slug))
    assert length(after_seed.panels) == length(expected_spec.panels),
           "seed_all must complete a dashboard that exists with no panels"

    assert after_seed.id == empty_dashboard.id, "same dashboard record, not a duplicate"
  end

  @tag :web_ng_shared_fixture_db
  test "leaves an unrelated dashboard untouched after seed_all", %{actor: actor, marker: marker} do
    {:ok, unrelated} =
      AuthoredDashboard
      |> Ash.Changeset.for_create(:create, %{
        dashboard_ref: Enum.random(1_000_000..9_999_999),
        title: "#{marker}-unrelated",
        slug: "#{marker}-unrelated-slug",
        visibility: :private,
        status: :active
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_seed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: "#{marker}-unrelated-slug"})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert after_seed, "unrelated dashboard must still exist after seed_all"
    assert after_seed.id == unrelated.id
    assert after_seed.title == "#{marker}-unrelated"
    assert after_seed.panels == [], "unrelated dashboard must have no panels added to it"
  end

  defp cleanup!(marker) do
    slug_pattern = "#{marker}-%"

    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: like(d.slug, ^slug_pattern)
      )
    )

    builtin_slugs = [SystemReports.new_devices_slug(), SystemReports.mtr_path_analytics_slug()]

    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: d.slug in ^builtin_slugs
      )
    )
  end
end
