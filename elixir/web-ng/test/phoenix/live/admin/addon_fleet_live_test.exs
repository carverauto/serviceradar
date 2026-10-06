defmodule ServiceRadarWebNGWeb.Admin.AddonFleetLiveTest do
  @moduledoc """
  DB-backed LiveView tests for the add-on fleet page (issue 4384):
  one card per agent with an add-on row group, honest drift rendering for every
  presence combination, and catalog-only inventory separated from fleet rows.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus

  require Ash.Query

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  # GitHub #4454: addon_statuses rows are never deleted, so an agent's last
  # report from months ago kept rendering as a current red "degraded" badge.
  test "a months-old status renders as stale, not as its last reported state",
       %{conn: conn, actor: _actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-stale-addon-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-gw-#{unique}", component_id: "fleet-comp-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-agent-#{unique}", name: "Fleet Agent #{unique}"})

    report_status!(agent.uid, addon_id,
      state: "degraded",
      active: true,
      version: "0.3.1",
      reported_at: DateTime.shift(DateTime.utc_now(), day: -30)
    )

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/fleet")

    assert html =~ "stale: last degraded"
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

    assert count_occurrences(html, ~s(data-role="agent-addon-card")) == 1
    assert count_occurrences(html, ~s(data-role="agent-card-label")) == 1
    assert count_occurrences(html, ~s(data-role="fleet-row")) == 3
    assert html =~ ~s(data-role="version-up-to-date")
    assert html =~ "up to date"

    assert html =~ ~s(data-role="version-running-unassigned")
    assert html =~ "(unassigned)"

    assert html =~ ~s(data-role="version-not-reported")
    assert html =~ "not reported"

    # No fabricated comparisons anywhere.
    refute html =~ "drift:"
    refute html =~ "0.0.0"
  end

  test "disabled assignment history never becomes current desired state", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-disabled-history-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-disabled-gw-#{unique}", component_id: "fleet-disabled-#{unique}"})

    agent =
      agent_fixture(gateway, %{
        uid: "fleet-disabled-agent-#{unique}",
        name: "Disabled History Agent"
      })

    old_approved = create_addon_package!(actor, addon_id, "0.2.0")
    newer_historical = create_addon_package!(actor, addon_id, "0.3.0")

    create_assignment!(actor, agent.uid, old_approved.id, enabled: false)
    create_assignment!(actor, agent.uid, newer_historical.id, enabled: false)
    report_status!(agent.uid, addon_id, state: "running", active: true, version: "0.3.0")

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/fleet")
    fleet_html = fleet_table_html(html)

    assert count_occurrences(fleet_html, ~s(data-role="fleet-row")) == 1
    assert fleet_html =~ ~s(data-role="version-running-unassigned")
    refute fleet_html =~ "newer approved: 0.2.0"
    refute fleet_html =~ "assignment disabled"

    html = render_click(lv, "toggle_details", %{"row" => "#{agent.uid}|#{addon_id}"})
    assert html =~ "Other assignments on this agent"
    assert html =~ "0.2.0"
    assert html =~ "0.3.0"
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

  test "required runtimes do not inflate the needs-attention count", %{conn: conn} do
    old_required_addons = Application.get_env(:serviceradar_core, :required_agent_addons)
    Application.put_env(:serviceradar_core, :required_agent_addons, ["otel-collector"])

    on_exit(fn ->
      if is_nil(old_required_addons) do
        Application.delete_env(:serviceradar_core, :required_agent_addons)
      else
        Application.put_env(:serviceradar_core, :required_agent_addons, old_required_addons)
      end
    end)

    unique = System.unique_integer([:positive])
    gateway = gateway_fixture(%{id: "fleet-required-gw-#{unique}", component_id: "fleet-required-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-required-agent-#{unique}", name: "Required Runtime Agent"})

    report_status!(agent.uid, "otel-collector", state: "running", active: true, version: "0.1.1")

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/fleet")
    fleet_html = fleet_table_html(html)

    assert fleet_html =~ ~s(data-role="version-required-runtime")
    assert fleet_html =~ "required runtime"
    assert fleet_html =~ ~s(data-role="assignment-required")
    refute fleet_html =~ "running, unassigned"
  end

  test "shows failed rollout evidence and the authorized retry control", %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-rollout-evidence-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-rollout-gw-#{unique}", component_id: "fleet-rollout-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-rollout-agent-#{unique}", name: "Rollout Evidence Agent"})

    previous = create_addon_package!(actor, addon_id, "1.0.0")
    candidate = create_addon_package!(actor, addon_id, "1.1.0")
    assignment = create_assignment!(actor, agent.uid, previous.id, enabled: true)

    rollout =
      AddonRollout
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          source_type: :assignment,
          source_id: assignment.id,
          previous_package_id: previous.id,
          candidate_package_id: candidate.id,
          trigger: :manual,
          state: :failed,
          policy: %{},
          target_snapshot: %{"eligible" => 1},
          blocked_reason: "candidate_health_timeout"
        },
        actor: actor
      )
      |> Ash.create!()

    target =
      AddonRolloutTarget
      |> Ash.Changeset.for_create(
        :create,
        %{
          rollout_id: rollout.id,
          assignment_id: assignment.id,
          agent_uid: agent.uid,
          addon_id: addon_id,
          source_type: :assignment,
          source_id: assignment.id,
          previous_package_id: previous.id,
          candidate_package_id: candidate.id,
          previous_params: %{},
          previous_args: [],
          batch_index: 0,
          classification: :eligible,
          state: :rolled_back,
          reason_code: "candidate_health_timeout"
        },
        actor: actor
      )
      |> Ash.create!()

    _target =
      target
      |> Ash.Changeset.for_update(
        :update,
        %{health_observed_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update!()

    report_status!(agent.uid, addon_id, state: "running", active: true, version: "1.0.0")

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/fleet")
    row_html = rollout_table_html(html)

    assert html =~ ~s(data-role="addon-rollout-row")
    assert html =~ "Retry"
    assert row_html =~ "Rollout Evidence Agent"
    assert row_html =~ "Direct assignment"
    assert row_html =~ "Failed"
    assert row_html =~ "never reported healthy on 1.1.0"
    assert row_html =~ "left on 1.0.0"
    refute row_html =~ to_string(assignment.id)
    refute row_html =~ "assignment ·"

    # Desired 1.0.0 is running. A finished canary must not paint the agent as blocked.
    fleet_html = fleet_table_html(html)
    assert fleet_html =~ "Healthy"
    refute fleet_html =~ "Update blocked"
    refute fleet_html =~ "action required"

    html = render_click(lv, "toggle_rollout_details", %{"id" => rollout.id})
    assert html =~ ~s(data-role="addon-rollout-detail")
    assert html =~ ~s(data-role="addon-rollout-target")
    assert html =~ "Rollout Evidence Agent"
    assert html =~ agent.uid
    assert html =~ "Rolled back"
    assert html =~ "Canary"
    assert html =~ "candidate never reported healthy in time"

    html =
      render_click(lv, "rollout_action", %{"id" => rollout.id, "operation" => "retry"})

    assert html =~ "Rollout retry accepted."
  end

  test "profile rollouts show the profile name instead of the profile UUID", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-rollout-profile-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-profile-gw-#{unique}", component_id: "fleet-profile-#{unique}"})

    agent =
      agent_fixture(gateway, %{
        uid: "fleet-profile-agent-#{unique}",
        name: "Profile Canary #{unique}"
      })

    previous = create_addon_package!(actor, addon_id, "2.0.0")
    candidate = create_addon_package!(actor, addon_id, "2.1.0")

    profile =
      ServiceRadar.Plugins.AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Linux canaries #{unique}",
          addon_package_id: previous.id,
          target_query: "in:agents",
          params: %{},
          args: [],
          enabled: true
        },
        actor: actor
      )
      |> Ash.create!()

    assignment = create_assignment!(actor, agent.uid, previous.id, enabled: true)

    rollout =
      AddonRollout
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          source_type: :profile,
          source_id: profile.id,
          previous_package_id: previous.id,
          candidate_package_id: candidate.id,
          trigger: :track_latest,
          state: :paused,
          policy: %{},
          target_snapshot: %{"eligible" => 1},
          blocked_reason: "candidate_reported_unhealthy"
        },
        actor: actor
      )
      |> Ash.create!()

    AddonRolloutTarget
    |> Ash.Changeset.for_create(
      :create,
      %{
        rollout_id: rollout.id,
        assignment_id: assignment.id,
        agent_uid: agent.uid,
        addon_id: addon_id,
        source_type: :profile,
        source_id: profile.id,
        previous_package_id: previous.id,
        candidate_package_id: candidate.id,
        previous_params: %{},
        previous_args: [],
        batch_index: 0,
        classification: :eligible,
        state: :rolled_back,
        reason_code: "candidate_reported_unhealthy"
      },
      actor: actor
    )
    |> Ash.create!()

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/fleet")
    row_html = rollout_table_html(html)

    assert row_html =~ "Linux canaries #{unique}"
    assert row_html =~ "Add-on profile"
    assert row_html =~ "Profile Canary #{unique}"
    assert row_html =~ "reported 2.1.0 as unhealthy"
    refute row_html =~ to_string(profile.id)
    refute row_html =~ "profile ·"
  end

  test "finished rollouts paginate so a long tail stays reachable", %{
    conn: conn,
    actor: actor
  } do
    import Ecto.Query

    unique = System.unique_integer([:positive])
    addon_id = "fleet-rollout-pages-#{unique}"
    gateway = gateway_fixture(%{id: "fleet-pages-gw-#{unique}", component_id: "fleet-pages-#{unique}"})
    agent = agent_fixture(gateway, %{uid: "fleet-pages-agent-#{unique}", name: "Pages Agent #{unique}"})

    previous = create_addon_package!(actor, addon_id, "1.0.0")
    candidate = create_addon_package!(actor, addon_id, "1.1.0")
    assignment = create_assignment!(actor, agent.uid, previous.id, enabled: true)
    active_assignment = create_assignment!(actor, agent.uid, candidate.id, enabled: true)

    base = DateTime.utc_now()

    finished_ids =
      for i <- 1..22 do
        attrs = %{
          addon_id: addon_id,
          source_type: :assignment,
          source_id: assignment.id,
          previous_package_id: previous.id,
          candidate_package_id: candidate.id,
          trigger: :track_latest,
          state: :completed,
          policy: %{},
          target_snapshot: %{"eligible" => 1},
          started_at: DateTime.shift(base, second: i)
        }

        attrs
        |> then(&Ash.Changeset.for_create(AddonRollout, :create, &1, actor: actor))
        |> Ash.create!()
        |> Map.fetch!(:id)
      end

    oldest_id = List.first(finished_ids)

    _active =
      %{
        addon_id: addon_id,
        source_type: :assignment,
        source_id: active_assignment.id,
        previous_package_id: previous.id,
        candidate_package_id: candidate.id,
        trigger: :track_latest,
        state: :running,
        policy: %{},
        target_snapshot: %{"eligible" => 1},
        started_at: DateTime.shift(base, minute: 1)
      }
      |> then(&Ash.Changeset.for_create(AddonRollout, :create, &1, actor: actor))
      |> Ash.create!()

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/fleet")

    # One active rollout visible; finished history stays behind the toggle.
    assert count_occurrences(html, ~s(data-role="addon-rollout-row")) == 1
    assert html =~ "Show finished (22)"

    html = render_click(lv, "toggle_finished_rollouts")

    # First page: the active rollout plus the 10 newest finished ones.
    assert count_occurrences(html, ~s(data-role="addon-rollout-row")) == 11
    assert html =~ "Showing 1-10 of 22"
    assert html =~ "Page 1 of 3"
    refute html =~ oldest_id

    html = render_click(lv, "finished_rollout_page", %{"page" => "3"})

    # Last page: the active rollout plus the 2 remaining finished ones,
    # including the oldest, which was unreachable before pagination.
    assert count_occurrences(html, ~s(data-role="addon-rollout-row")) == 3
    assert html =~ "Showing 21-22 of 22"
    assert html =~ "Page 3 of 3"
    assert html =~ oldest_id

    html = render_click(lv, "finished_rollout_page", %{"page" => "1"})
    assert html =~ "Showing 1-10 of 22"
    refute html =~ oldest_id
    render_click(lv, "toggle_finished_rollouts")
    render_click(lv, "focus_rollout", %{"id" => oldest_id})

    assert has_element?(lv, "#addon-rollout-#{oldest_id}")
    assert has_element?(lv, "[data-role='addon-rollout-detail']")
    assert has_element?(lv, "button", "Page 3 of 3")

    removed_ids = Enum.take(finished_ids, 2)
    assert {2, _} = ServiceRadar.Repo.delete_all(from(r in AddonRollout, where: r.id in ^removed_ids))

    render_click(lv, "refresh")

    assert has_element?(lv, "button", "Page 2 of 2")
    assert has_element?(lv, "#addon-finished-rollouts-next-page[disabled]")
    assert has_element?(lv, "#addon-rollout-#{Enum.at(finished_ids, 2)}")

    lv |> element("#addon-finished-rollouts-prev-page") |> render_click()

    assert has_element?(lv, "button", "Page 1 of 2")
    refute has_element?(lv, "#addon-rollout-#{Enum.at(finished_ids, 2)}")
  end

  @tag :web_ng_shared_fixture_db
  test "pages agent cards and keeps an open detail when returning to that page", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-page-addon-#{unique}"
    agents = seed_paged_agents!(actor, unique, addon_id, 11)
    first = hd(agents)
    last = List.last(agents)

    {:ok, view, _html} = live(conn, ~p"/settings/agents/addons/fleet")
    html = filter_fleet(view, %{"addon_id" => addon_id})

    assert html =~ "11 agent(s) · 11 add-on(s)"
    assert count_occurrences(html, ~s(data-role="agent-addon-card")) == 10
    assert has_element?(view, agent_card(first.uid))
    refute has_element?(view, agent_card(last.uid))
    assert html =~ "Showing 1-10 of 11"

    html = render_click(view, "toggle_details", %{"row" => "#{first.uid}|#{addon_id}"})
    assert html =~ "What to do"
    assert html =~ "no diagnostics reported"

    html = render_click(view, "agent_page", %{"page" => "2"})
    assert_patch(view, fleet_path(addon_id: addon_id, page: 2))
    assert has_element?(view, agent_card(last.uid))
    refute has_element?(view, agent_card(first.uid))
    refute html =~ "What to do"
    assert html =~ "Showing 11-11 of 11"
    assert html =~ "11 agent(s) · 11 add-on(s)"

    html = render_click(view, "agent_page", %{"page" => "1"})
    assert has_element?(view, agent_card(first.uid))
    refute has_element?(view, agent_card(last.uid))
    assert html =~ "What to do"
    assert html =~ "no diagnostics reported"
  end

  @tag :web_ng_shared_fixture_db
  test "changing the fleet filter resets agent pagination", %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-filter-page-#{unique}"
    agents = seed_paged_agents!(actor, unique, addon_id, 11)
    first = hd(agents)
    last = List.last(agents)

    {:ok, view, _html} = live(conn, ~p"/settings/agents/addons/fleet")
    filter_fleet(view, %{"addon_id" => addon_id})
    render_click(view, "agent_page", %{"page" => "2"})
    assert has_element?(view, agent_card(last.uid))
    refute has_element?(view, agent_card(first.uid))

    html =
      filter_fleet(view, %{"agent_uid" => first.uid, "addon_id" => addon_id})

    assert_patch(view, fleet_path(addon_id: addon_id, agent_uid: first.uid))
    assert html =~ "1 agent(s) · 1 add-on(s)"
    assert has_element?(view, agent_card(first.uid))
    refute has_element?(view, agent_card(last.uid))
    refute has_element?(view, "#addon-fleet-agents-next-page")

    html = filter_fleet(view, %{"addon_id" => addon_id})
    assert html =~ "11 agent(s) · 11 add-on(s)"
    assert html =~ "Showing 1-10 of 11"
    assert has_element?(view, agent_card(first.uid))
    refute has_element?(view, agent_card(last.uid))

    html = filter_fleet(view, %{"addon_id" => "fleet-missing-#{unique}"})
    assert html =~ "No matching add-on deployments"
    assert count_occurrences(html, ~s(data-role="agent-addon-card")) == 0
    assert html =~ "0 agent(s) · 0 add-on(s)"
  end

  @tag :web_ng_shared_fixture_db
  test "a fleet URL restores its filters and agent page, and the static render holds no fleet rows",
       %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])
    addon_id = "fleet-url-page-#{unique}"
    agents = seed_paged_agents!(actor, unique, addon_id, 11)
    first = hd(agents)
    last = List.last(agents)
    path = fleet_path(addon_id: addon_id, page: 2)

    static_html = conn |> get(path) |> html_response(200)
    assert static_html =~ ~s(id="addon-fleet-loading")
    refute static_html =~ ~s(data-role="agent-addon-card")

    {:ok, view, html} = live(conn, path)
    assert html =~ "11 agent(s) · 11 add-on(s)"
    assert html =~ "Showing 11-11 of 11"
    assert has_element?(view, agent_card(last.uid))
    refute has_element?(view, agent_card(first.uid))
    refute has_element?(view, "#addon-fleet-loading")

    render_click(view, "clear_filters", %{})
    assert_patch(view, "/settings/agents/addons/fleet")
  end

  defp fleet_path(params), do: "/settings/agents/addons/fleet?" <> URI.encode_query(params)

  defp seed_paged_agents!(actor, unique, addon_id, count) do
    package = create_addon_package!(actor, addon_id, "1.0.0")

    gateway =
      gateway_fixture(%{id: "fleet-page-gw-#{unique}", component_id: "fleet-page-comp-#{unique}"})

    for n <- 1..count do
      label = n |> Integer.to_string() |> String.pad_leading(2, "0")

      agent =
        agent_fixture(gateway, %{
          uid: "fleet-page-agent-#{unique}-#{label}",
          name: "Fleet Page #{unique} #{label}"
        })

      create_assignment!(actor, agent.uid, package.id, enabled: true)
      report_status!(agent.uid, addon_id, state: "running", active: true, version: "1.0.0")
      agent
    end
  end

  defp filter_fleet(view, filter) do
    render_change(view, "filter", %{
      "filter" =>
        Map.merge(
          %{
            "agent_uid" => "",
            "addon_id" => "",
            "category" => "",
            "attention_only" => "false"
          },
          filter
        )
    })
  end

  defp agent_card(agent_uid) do
    ~s([data-role="agent-addon-card"][data-agent-uid="#{agent_uid}"])
  end

  # The fleet matrix table markup (everything before the catalog inventory
  # panel), so assertions can scope to fleet rows only.
  defp fleet_table_html(html) do
    case String.split(html, "Catalog inventory", parts: 2) do
      [fleet, _catalog] -> fleet
      [all] -> all
    end
  end

  defp rollout_table_html(html) do
    case String.split(html, "Agent add-on inventory", parts: 2) do
      [before, _rest] -> before
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
        reported_at: Keyword.get(opts, :reported_at, DateTime.utc_now())
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
