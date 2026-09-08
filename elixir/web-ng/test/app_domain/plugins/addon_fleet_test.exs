defmodule ServiceRadarWebNG.Plugins.AddonFleetTest do
  @moduledoc """
  Pure unit tests for the add-on fleet query/transform layer.

  These exercise the in-memory matrix transforms (`filter/2`, `summary/1`,
  `addon_ids/1`, `agents/1`) with hand-built rows, so they need no database.
  The DB-backed read path (`rows/1`) is covered by the DB-gated LiveView tests
  and is not exercised here.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadarWebNG.Plugins.AddonFleet

  @moduletag :db_free

  # A row shaped like AddonFleet.row(); only the keys the transforms read are
  # load-bearing, but we keep the full shape so the test fixtures stay honest.
  defp row(overrides) do
    base = %{
      agent_uid: "agent-1",
      agent_label: "alpha (agent-1)",
      addon_id: "endpoint-inventory",
      addon_name: "Endpoint Inventory",
      package_id: "pkg-1",
      assigned_version: "1.0.0",
      latest_approved_version: "1.0.0",
      content_hash: "sha256:abc",
      package_status: :approved,
      verification_status: "verified",
      approved?: true,
      assigned?: true,
      enabled?: true,
      management_mode: :assignment,
      running_state: "running",
      running_version: "1.0.0",
      active?: true,
      degradation_reason: nil,
      reported_at: ~U[2026-06-15 00:00:00Z],
      last_scan_at: ~U[2026-06-15 00:00:00Z],
      collector?: true,
      version_status: {:up_to_date, "1.0.0", true},
      stale_assignments: [],
      category: :healthy,
      reason_code: "desired_runtime_healthy",
      evidence_age_seconds: 0,
      rollout_state: nil,
      attention: [],
      attention?: false
    }

    Map.merge(base, Map.new(overrides))
  end

  defp package(overrides) do
    base = %AddonPackage{
      id: Ecto.UUID.generate(),
      addon_id: "netprobe",
      name: "Netprobe",
      version: "1.0.0",
      status: :approved,
      imported_at: ~U[2026-06-01 00:00:00Z],
      inserted_at: ~U[2026-06-01 00:00:00Z]
    }

    struct!(base, Map.new(overrides))
  end

  describe "filter/2" do
    setup do
      rows = [
        row(agent_uid: "agent-1", addon_id: "endpoint-inventory", attention: [], attention?: false),
        row(
          agent_uid: "agent-1",
          addon_id: "netprobe",
          category: :action_required,
          attention: [:stopped_or_inactive],
          attention?: true
        ),
        row(agent_uid: "agent-2", addon_id: "endpoint-inventory", attention: [], attention?: false),
        row(
          agent_uid: nil,
          addon_id: "scalibr-endpoint-inventory",
          agent_label: "— (catalog only)",
          category: :action_required,
          attention: [:staged_not_approved],
          attention?: true
        )
      ]

      {:ok, rows: rows}
    end

    test "no filters returns all rows", %{rows: rows} do
      assert AddonFleet.filter(rows, %{}) == rows
    end

    test "blank string filters are treated as no filter", %{rows: rows} do
      filters = %{"agent_uid" => "", "addon_id" => "  ", "attention_only" => "false"}
      assert AddonFleet.filter(rows, filters) == rows
    end

    test "filters by agent_uid", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"agent_uid" => "agent-1"})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.agent_uid == "agent-1"))
    end

    test "filters by addon_id", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"addon_id" => "endpoint-inventory"})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.addon_id == "endpoint-inventory"))
    end

    test "attention_only keeps only flagged rows", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"attention_only" => "true"})
      assert length(result) == 2
      assert Enum.all?(result, & &1.attention?)
    end

    test "attention_only accepts boolean true and \"on\"", %{rows: rows} do
      assert AddonFleet.filter(rows, %{"attention_only" => true}) ==
               AddonFleet.filter(rows, %{"attention_only" => "true"})

      assert AddonFleet.filter(rows, %{"attention_only" => "on"}) ==
               AddonFleet.filter(rows, %{"attention_only" => "true"})
    end

    test "combines agent and addon filters", %{rows: rows} do
      result =
        AddonFleet.filter(rows, %{"agent_uid" => "agent-1", "addon_id" => "netprobe"})

      assert [%{agent_uid: "agent-1", addon_id: "netprobe"}] = result
    end

    test "combines an attention filter with an agent filter", %{rows: rows} do
      result =
        AddonFleet.filter(rows, %{"agent_uid" => "agent-1", "attention_only" => "true"})

      assert [%{addon_id: "netprobe"}] = result
    end

    test "filters by mutually exclusive health category", %{rows: rows} do
      result = AddonFleet.filter(rows, %{"category" => "action_required"})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.category == :action_required))
    end
  end

  describe "summary/1" do
    test "counts operationally distinct health categories" do
      rows = [
        row(category: :healthy),
        row(category: :updating),
        row(category: :action_required),
        row(category: :unavailable),
        row(category: :expected_inactive),
        row(category: :observed_only, assigned?: false, enabled?: false)
      ]

      assert AddonFleet.summary(rows) == %{
               managed: 5,
               healthy: 1,
               updating: 1,
               action_required: 1,
               unavailable: 1,
               expected_inactive: 1,
               observed_only: 1
             }
    end

    test "is all-zero for an empty fleet" do
      assert AddonFleet.summary([]) == %{
               managed: 0,
               healthy: 0,
               updating: 0,
               action_required: 0,
               unavailable: 0,
               expected_inactive: 0,
               observed_only: 0
             }
    end
  end

  describe "classify/7" do
    setup do
      now = ~U[2026-07-18 14:00:00Z]

      package =
        package(
          supervision: :agent_sidecar,
          status: :approved,
          version: "1.0.0"
        )

      assignment = %AddonAssignment{
        id: Ecto.UUID.generate(),
        enabled: true,
        inserted_at: DateTime.add(now, -60),
        updated_at: DateTime.add(now, -60)
      }

      agent = %Agent{
        status: :connected,
        is_healthy: true,
        last_seen_time: DateTime.add(now, -5)
      }

      status = %AddonStatus{
        state: "running",
        active: true,
        version: "1.0.0",
        reported_at: DateTime.add(now, -5)
      }

      base = %{assigned_version: "1.0.0"}

      {:ok, now: now, package: package, assignment: assignment, agent: agent, status: status, base: base}
    end

    test "keeps fresh runtime failures actionable", context do
      status = %{context.status | state: "unhealthy", degradation_reason: "unit_failed"}

      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               status,
               context.agent,
               nil,
               context.now
             ) == {:action_required, "runtime_reported_unhealthy"}
    end

    test "classifies offline or stale desired state as unavailable, not a current failure", context do
      agent = %{context.agent | status: :disconnected, last_seen_time: DateTime.add(context.now, -600)}
      status = %{context.status | state: "unhealthy", reported_at: DateTime.add(context.now, -600)}

      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               status,
               agent,
               nil,
               context.now
             ) == {:unavailable, "agent_unavailable_or_stale"}
    end

    test "classifies a never-reported assignment as unavailable", context do
      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               nil,
               context.agent,
               nil,
               context.now
             ) == {:unavailable, "desired_runtime_not_yet_reported"}
    end

    test "keeps healthy built-ins and stale observations informational", context do
      assert AddonFleet.classify(
               context.base,
               context.package,
               nil,
               context.status,
               context.agent,
               nil,
               context.now
             ) == {:observed_only, "healthy_observed_only_runtime"}

      stale_unhealthy = %{
        context.status
        | state: "unhealthy",
          reported_at: DateTime.add(context.now, -600)
      }

      assert AddonFleet.classify(
               context.base,
               context.package,
               nil,
               stale_unhealthy,
               context.agent,
               nil,
               context.now
             ) == {:observed_only, "observed_only_stale"}
    end

    test "keeps a fresh unhealthy observed-only runtime actionable", context do
      status = %{context.status | state: "failed"}

      assert AddonFleet.classify(
               context.base,
               context.package,
               nil,
               status,
               context.agent,
               nil,
               context.now
             ) == {:action_required, "runtime_reported_unhealthy"}
    end

    test "classifies a ready ephemeral helper as expected inactive", context do
      package = %{context.package | supervision: :ephemeral_helper}
      status = %{context.status | state: "ready", active: false}

      assert AddonFleet.classify(
               context.base,
               package,
               context.assignment,
               status,
               context.agent,
               nil,
               context.now
             ) == {:expected_inactive, "ephemeral_helper_ready"}
    end

    test "shows incompatible and in-progress rollout targets truthfully", context do
      incompatible_target = %{
        rollout_state: :completed,
        state: :excluded,
        classification: :incompatible,
        reason_code: "unsupported_platform"
      }

      offline_agent = %{context.agent | status: :disconnected, last_seen_time: DateTime.add(context.now, -600)}

      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               context.status,
               offline_agent,
               incompatible_target,
               context.now
             ) == {:action_required, "unsupported_platform"}

      failed_rollout = %{
        rollout_state: :failed,
        state: :failed,
        reason_code: "candidate_health_timeout"
      }

      # Finished canary records must not override a live, desired version.
      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               context.status,
               context.agent,
               failed_rollout,
               context.now
             ) == {:healthy, "desired_runtime_healthy"}

      paused_and_converged = %{
        rollout_state: :paused,
        state: :rolled_back,
        reason_code: "candidate_health_timeout"
      }

      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               context.status,
               context.agent,
               paused_and_converged,
               context.now
             ) == {:healthy, "desired_runtime_healthy"}

      paused_and_behind = %{
        rollout_state: :paused,
        state: :rolled_back,
        reason_code: "candidate_health_timeout"
      }

      assert AddonFleet.classify(
               %{assigned_version: "1.1.0"},
               context.package,
               context.assignment,
               context.status,
               context.agent,
               paused_and_behind,
               context.now
             ) == {:action_required, "candidate_health_timeout"}

      active_rollout = %{
        rollout_state: :running,
        state: :waiting_health,
        reason_code: "waiting_for_fresh_candidate_health"
      }

      assert AddonFleet.classify(
               context.base,
               context.package,
               context.assignment,
               context.status,
               context.agent,
               active_rollout,
               context.now
             ) == {:updating, "waiting_for_fresh_candidate_health"}
    end
  end

  describe "addon_ids/1" do
    test "returns the distinct, sorted add-on ids" do
      rows = [
        row(addon_id: "netprobe"),
        row(addon_id: "endpoint-inventory"),
        row(addon_id: "netprobe"),
        row(addon_id: "scalibr-endpoint-inventory")
      ]

      assert AddonFleet.addon_ids(rows) ==
               ["endpoint-inventory", "netprobe", "scalibr-endpoint-inventory"]
    end

    test "is empty for no rows" do
      assert AddonFleet.addon_ids([]) == []
    end
  end

  describe "version_status/1" do
    test "assigned and running the same version is up to date; only a greater approved version is newer" do
      assert AddonFleet.version_status(
               row(
                 assigned_version: "0.1.20",
                 running_version: "0.1.20",
                 latest_approved_version: "0.1.20"
               )
             ) == {:up_to_date, "0.1.20", true}

      assert AddonFleet.version_status(
               row(
                 assigned_version: "0.1.19",
                 running_version: "0.1.19",
                 latest_approved_version: "0.1.20"
               )
             ) == {:up_to_date, "0.1.19", false}

      assert AddonFleet.version_status(
               row(
                 assigned_version: "0.3.0",
                 running_version: "0.3.0",
                 latest_approved_version: "0.2.0"
               )
             ) == {:up_to_date, "0.3.0", true}
    end

    test "assigned and running different versions is a two-sided drift comparison" do
      assert AddonFleet.version_status(row(assigned_version: "0.1.20", running_version: "0.1.19")) ==
               {:drift, "0.1.19", "0.1.20"}
    end

    test "running with no assignment reports running_unassigned, never a fabricated drift" do
      assert AddonFleet.version_status(
               row(
                 assigned?: false,
                 assigned_version: nil,
                 management_mode: :observed,
                 running_version: "0.1.19"
               )
             ) ==
               {:running_unassigned, "0.1.19"}

      # Observed state without a version string still reads as running/unassigned.
      assert AddonFleet.version_status(
               row(
                 assigned?: false,
                 assigned_version: nil,
                 management_mode: :observed,
                 running_version: nil,
                 running_state: "running"
               )
             ) == {:running_unassigned, nil}
    end

    test "required runtime is not described as unassigned" do
      assert AddonFleet.version_status(
               row(
                 assigned?: false,
                 assigned_version: nil,
                 management_mode: :required,
                 running_version: "0.1.1",
                 running_state: "running"
               )
             ) == {:required_runtime, "0.1.1"}
    end

    test "assigned with no observed status reports not_reported" do
      assert AddonFleet.version_status(row(assigned_version: "0.1.20", running_version: nil, running_state: nil)) ==
               {:not_reported, "0.1.20"}
    end

    test "nothing present yields nil (no comparison at all)" do
      assert AddonFleet.version_status(
               row(
                 assigned?: false,
                 assigned_version: nil,
                 running_version: nil,
                 running_state: nil
               )
             ) == nil
    end

    test "assigned with unknown assigned version and observed status says nothing" do
      assert AddonFleet.version_status(row(assigned_version: nil, running_version: "0.1.19")) ==
               nil
    end
  end

  describe "latest_package/1 and latest_approved_version/1" do
    test "an older version imported later never becomes latest" do
      newer = package(version: "0.1.20", imported_at: ~U[2026-06-01 00:00:00Z])
      older_but_recent = package(version: "0.1.19", imported_at: ~U[2026-07-01 00:00:00Z])

      assert AddonFleet.latest_package([older_but_recent, newer]).version == "0.1.20"
      assert AddonFleet.latest_approved_version([older_but_recent, newer]) == "0.1.20"
    end

    test "approved packages are preferred over newer staged ones" do
      staged_newer = package(version: "0.2.0", status: :staged)
      approved_older = package(version: "0.1.20", status: :approved)

      assert AddonFleet.latest_package([staged_newer, approved_older]).version == "0.1.20"
      assert AddonFleet.latest_approved_version([staged_newer, approved_older]) == "0.1.20"
    end

    test "falls back to all packages when nothing is approved; approved-only lookup is nil" do
      staged = package(version: "0.2.0", status: :staged)

      assert AddonFleet.latest_package([staged]).version == "0.2.0"
      assert AddonFleet.latest_approved_version([staged]) == nil
      assert AddonFleet.latest_package([]) == nil
      assert AddonFleet.latest_approved_version([]) == nil
    end

    test "non-semver version strings do not crash and fall back to import recency" do
      weird_old = package(version: "netprobe-demo", imported_at: ~U[2026-06-01 00:00:00Z])
      weird_new = package(version: "also-not-semver", imported_at: ~U[2026-07-01 00:00:00Z])

      assert AddonFleet.latest_package([weird_old, weird_new]).version == "also-not-semver"
    end
  end

  describe "compare_versions/2" do
    test "compares semver and tolerates garbage" do
      assert AddonFleet.compare_versions("0.1.20", "0.1.19") == :gt
      assert AddonFleet.compare_versions("0.1.19", "0.1.20") == :lt
      assert AddonFleet.compare_versions("0.1.20", "0.1.20") == :eq
      assert AddonFleet.compare_versions("not-semver", "0.1.20") == :incomparable
      assert AddonFleet.compare_versions(nil, "0.1.20") == :incomparable
    end
  end

  describe "agents/1" do
    test "returns distinct {label, uid}, case-insensitively sorted by label" do
      rows = [
        row(agent_uid: "agent-2", agent_label: "Bravo (agent-2)"),
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)"),
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)")
      ]

      assert AddonFleet.agents(rows) == [
               {"alpha (agent-1)", "agent-1"},
               {"Bravo (agent-2)", "agent-2"}
             ]
    end

    test "excludes catalog-only rows that have no agent" do
      rows = [
        row(agent_uid: "agent-1", agent_label: "alpha (agent-1)"),
        row(agent_uid: nil, agent_label: "— (catalog only)")
      ]

      assert AddonFleet.agents(rows) == [{"alpha (agent-1)", "agent-1"}]
    end

    test "is empty for no rows" do
      assert AddonFleet.agents([]) == []
    end
  end
end
