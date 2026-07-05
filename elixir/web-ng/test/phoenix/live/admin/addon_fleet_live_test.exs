defmodule ServiceRadarWebNGWeb.Admin.AddonFleetLiveTest do
  @moduledoc """
  DB-backed LiveView tests for the add-on fleet page (issue 4384):
  one row per (agent, add-on), honest drift rendering for every presence
  combination, and catalog-only inventory separated from fleet rows.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonStatus

  require Ash.Query

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  test "one row per (agent, add-on): stale assignment collapses into detail and drift shows both sides",
       %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-drift-addon-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-gw-#{unique}", component_id: "fleet-comp-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-agent-#{unique}", name: "Fleet Agent #{unique}"})

    older = create_addon_package!(actor, addon_id, "0.1.19")
    newer = create_addon_package!(actor, addon_id, "0.1.20")

    create_assignment!(actor, agent.uid, older.id, enabled: false)
    create_assignment!(actor, agent.uid, newer.id, enabled: true)
    report_status!(agent.uid, addon_id, state: "running", active: true, version: "0.1.19")

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/fleet")

    # Exactly one fleet row for the (agent, add-on) pair despite two assignments.
    assert count_occurrences(html, ~s(data-role="fleet-row")) == 1

    # Drift is a two-sided comparison, never a bare/zero version.
    assert html =~ ~s(data-role="version-drift")
    assert html =~ "0.1.19"
    assert html =~ "0.1.20"
    assert html =~ "→ assigned"
    refute html =~ "drift:"
    assert html =~ "version drift"

    # The superseded assignment is reachable via the row detail, not a peer row.
    html = render_click(lv, "toggle_details", %{"row" => "#{agent.uid}|#{addon_id}"})
    assert html =~ "Other assignments on this agent"
    assert html =~ "0.1.19"
  end

  test "renders honest states for every assignment/status presence combination",
       %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    gateway = gateway_fixture(%{id: "fleet-gw2-#{unique}", component_id: "fleet-comp2-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-agent2-#{unique}", name: "Fleet Agent Two #{unique}"})

    # Up to date: assigned == running == latest approved.
    current_addon = "fleet-current-#{unique}"
    current = create_addon_package!(actor, current_addon, "0.1.20")
    create_assignment!(actor, agent.uid, current.id, enabled: true)
    report_status!(agent.uid, current_addon, state: "running", active: true, version: "0.1.20")

    # Running with no assignment.
    orphan_addon = "fleet-orphan-#{unique}"
    report_status!(agent.uid, orphan_addon, state: "running", active: true, version: "0.3.0")

    # Assigned but never reported.
    silent_addon = "fleet-silent-#{unique}"
    silent = create_addon_package!(actor, silent_addon, "1.2.3")
    create_assignment!(actor, agent.uid, silent.id, enabled: true)

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/fleet")

    assert html =~ ~s(data-role="version-up-to-date")
    assert html =~ "up to date"

    assert html =~ ~s(data-role="version-running-unassigned")
    assert html =~ "(unassigned)"
    assert html =~ "running, unassigned"

    assert html =~ ~s(data-role="version-not-reported")
    assert html =~ "not reported"
    assert html =~ "assigned, not running"

    # No fabricated comparisons anywhere.
    refute html =~ "drift:"
    refute html =~ "0.0.0"
  end

  test "catalog-only packages appear in the inventory section, never as fleet rows",
       %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-catalog-only-#{unique}"
    create_addon_package!(actor, addon_id, "2.0.0")

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/fleet")

    assert html =~ "Catalog inventory"
    assert html =~ ~s(data-role="catalog-only-row")
    assert html =~ addon_id
    refute html =~ "— (catalog only)"

    # The catalog-only add-on must not surface as an agentless fleet row.
    refute fleet_table_html(html) =~ addon_id
  end

  # The fleet matrix table markup (everything before the catalog inventory
  # panel), so assertions can scope to fleet rows only.
  defp fleet_table_html(html) do
    case String.split(html, "Catalog inventory", parts: 2) do
      [fleet, _catalog] -> fleet
      [all] -> all
    end
  end

  defp count_occurrences(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp create_addon_package!(actor, addon_id, version) do
    attrs = %{
      addon_id: addon_id,
      name: "Fleet #{addon_id}",
      version: version,
      description: "Fleet LiveView test add-on",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-addon",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: ["addon.run"],
      config_schema: %{},
      artifacts: %{},
      requires: %{},
      source_type: :first_party,
      source_oci_ref: "registry.carverauto.dev/serviceradar/addon:test",
      source_oci_digest: "sha256:test-#{addon_id}-#{version}",
      source_release_tag: "v1.0.0",
      source_metadata: %{},
      imported_at: DateTime.utc_now(),
      verification_status: "verified"
    }

    package =
      AddonPackage
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!()

    package
    |> Ash.Changeset.for_update(:approve, %{approved_capabilities: ["addon.run"]}, actor: actor)
    |> Ash.update!()
  end

  defp create_assignment!(actor, agent_uid, addon_package_id, opts) do
    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        addon_package_id: addon_package_id,
        enabled: Keyword.get(opts, :enabled, true),
        params: %{},
        args: []
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp report_status!(agent_uid, addon_id, opts) do
    AddonStatus
    |> Ash.Changeset.for_create(
      :report,
      %{
        agent_uid: agent_uid,
        addon_id: addon_id,
        state: Keyword.fetch!(opts, :state),
        active: Keyword.fetch!(opts, :active),
        version: Keyword.get(opts, :version),
        reported_at: DateTime.utc_now()
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
