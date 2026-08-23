defmodule ServiceRadar.Plugins.AddonRolloutEligibilityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility

  @moduletag :db_free

  test "selects the newest stable trusted candidate within the capability ceiling" do
    current = package(version: "1.0.0")
    older = package(version: "1.1.0")
    newest = package(version: "1.2.0")
    prerelease = package(version: "2.0.0-beta.1")

    assert {:ok, ^newest} =
             Eligibility.latest_candidate(current, [prerelease, older, newest], source())
  end

  test "fails closed when the only newer candidate expands privileges" do
    current = package(version: "1.0.0")
    privileged = package(version: "1.1.0", approved_capabilities: ["network", "root"])

    assert {:blocked, :capability_ceiling_exceeded, ^privileged} =
             Eligibility.latest_candidate(current, [privileged], source())
  end

  test "does not select staged, unverified, mutable, or already blocked candidates" do
    current = package(version: "1.0.0")
    staged = package(version: "1.4.0", status: :staged)
    unverified = package(version: "1.3.0", verification_status: "failed")
    mutable = package(version: "1.2.0", source_oci_digest: nil)
    blocked = package(version: "1.1.0")

    assert :none =
             Eligibility.latest_candidate(
               current,
               [staged, unverified, mutable, blocked],
               source(),
               blocked_candidate_ids: [blocked.id]
             )
  end

  test "permits an explicitly tracked verified third-party origin without crossing repositories" do
    current =
      package(
        version: "1.0.0",
        source_type: :imported,
        source_oci_ref: "registry.example/vendor/netprobe:v1.0.0"
      )

    candidate =
      package(
        version: "1.1.0",
        source_type: :imported,
        source_oci_ref: "registry.example/vendor/netprobe:v1.1.0"
      )

    different_origin =
      package(
        version: "2.0.0",
        source_type: :imported,
        source_oci_ref: "registry.example/other/netprobe:v2.0.0"
      )

    assert {:ok, ^candidate} =
             Eligibility.latest_candidate(current, [different_origin, candidate], source())
  end

  test "classifies fresh compatible agents separately from unavailable and incompatible agents" do
    now = ~U[2026-07-18 17:00:00Z]
    candidate = package(version: "1.1.0")

    assert {:eligible, nil} = Eligibility.classify_target(candidate, agent(now), now)

    assert {:unavailable, "agent_unavailable_or_stale"} =
             Eligibility.classify_target(candidate, agent(now, status: :disconnected), now)

    assert {:incompatible, "missing_platform_artifact"} =
             Eligibility.classify_target(candidate, agent(now, arch: "arm64"), now)
  end

  test "a containerized agent that predates the capability loses only systemd add-ons" do
    now = ~U[2026-07-18 17:00:00Z]

    # The airtight claim, and only it: no host system unit dir, no root-owned updater.
    for supervision <- [:systemd_service, :systemd_timer],
        deployment_type <- ["kubernetes", "docker", "lxc", "container"] do
      assert {:incompatible, "agent_cannot_host_native_addons"} =
               Eligibility.classify_target(
                 package(supervision: supervision),
                 agent(now, deployment_type: deployment_type),
                 now
               )
    end

    # Nothing is inferred about the rest: a sidecar is just a subprocess.
    for supervision <- [:agent_sidecar, :ephemeral_helper, :config_toggle] do
      assert {:eligible, nil} =
               Eligibility.classify_target(
                 package(supervision: supervision),
                 agent(now, deployment_type: "kubernetes"),
                 now
               )
    end
  end

  test "a bare-metal agent still hosts systemd add-ons" do
    now = ~U[2026-07-18 17:00:00Z]

    assert {:eligible, nil} =
             Eligibility.classify_target(
               package(supervision: :systemd_timer),
               agent(now, deployment_type: "bare-metal"),
               now
             )
  end

  test "a reported native-addon-host capability is believed for every supervision model" do
    now = ~U[2026-07-18 17:00:00Z]

    # An agent that says it hosts none of them is excluded from ALL of them -- the
    # in-cluster agent refuses the whole assignment set, so a sidecar is no more
    # hostable there than a systemd unit, and leaving it "eligible" for sidecars is
    # exactly what left a silent target to time out the rollout.
    for supervision <- [:systemd_service, :agent_sidecar, :ephemeral_helper, :config_toggle] do
      assert {:incompatible, "agent_cannot_host_native_addons"} =
               Eligibility.classify_target(
                 package(supervision: supervision),
                 agent(now,
                   deployment_type: "kubernetes",
                   capabilities: ["addon.native.host.unavailable"]
                 ),
                 now
               )
    end

    # ...and a privileged container that says it CAN is trusted over the guess.
    assert {:eligible, nil} =
             Eligibility.classify_target(
               package(supervision: :systemd_service),
               agent(now, deployment_type: "docker", capabilities: ["addon.native.host"]),
               now
             )
  end

  test "an agent that reports no deployment type is left eligible" do
    now = ~U[2026-07-18 17:00:00Z]

    # Older agents predate deployment_type reporting. Failing closed here would
    # strand every real bare-metal host in an existing fleet, so stay permissive
    # and let the health gate speak.
    assert {:eligible, nil} =
             Eligibility.classify_target(package(supervision: :systemd_service), agent(now), now)
  end

  test "uses supervision-specific readiness instead of requiring every add-on to be active" do
    timer = package(supervision: :systemd_timer)
    helper = package(supervision: :ephemeral_helper)
    service = package(supervision: :systemd_service)

    refute Eligibility.supervision_ready?(service, %{state: "ready", active: false})
    assert Eligibility.supervision_ready?(timer, %{state: "waiting", active: false})
    assert Eligibility.supervision_ready?(helper, %{state: "staged", active: false})
  end

  # netprobe now also serves the generic AddonService on a second socket
  # (refactor-netprobe-onto-generic-addon-contract task 3.1). Its lifecycle state
  # still comes from the systemd unit, unchanged -- but that chain crosses
  # Go -> proto -> Elixir on a bare string, and `tolerated_failures: 0` means one
  # target that cannot report add-on health fails the rollout for the ENTIRE
  # fleet. A version bump on netprobe mints a new AddonPackage and a rollout, so
  # this is exercised on every netprobe release.
  describe "a systemd-supervised netprobe stays rollout-eligible" do
    test "the exact state the agent reports for a running systemd unit is accepted" do
      # "running" is agentaddon.StateRunning (go/pkg/agent/addon/types.go), which
      # push_loop_capabilities reports for a netprobe unit that is up, and which
      # addon_status_ingestor turns into active: state == "running".
      #
      # If either side of that renames the string, netprobe silently stops being
      # rollout-eligible and every rollout containing it fails fleet-wide.
      service = package(supervision: :systemd_service)

      assert Eligibility.supervision_state_ready?(service, %{state: "running", active: true}),
             "a running netprobe unit must satisfy the systemd supervision model"
    end

    test "active is derived from the state, so the two cannot disagree" do
      # addon_status_ingestor sets active: state == "running". A status claiming
      # to be running while inactive cannot come from that path -- and if it ever
      # did, the gate must not accept it.
      service = package(supervision: :systemd_service)

      refute Eligibility.supervision_state_ready?(service, %{state: "running", active: false})
      refute Eligibility.supervision_state_ready?(service, %{state: "stopped", active: true})
    end

    test "serving AddonService does not change the state netprobe reports" do
      # The AddonService socket is additive: netprobe stays a systemd unit and
      # its lifecycle state still comes from that unit, not from whether the new
      # socket is being served. Pinned so a later cutover step cannot quietly
      # start gating rollouts on the new transport.
      service = package(supervision: :systemd_service)

      for state <- ["running", "active", "healthy", "degraded"] do
        assert Eligibility.supervision_state_ready?(service, %{state: state, active: true}),
               "#{state} must remain acceptable for a systemd add-on"
      end
    end
  end

  # Every reason string below is one the demo fleet actually reported on
  # 2026-08-09; see openspec/changes/fix-stuck-addon-rollouts. Rollout gating
  # asks supervision_state_ready?/2, which is about whether the add-on came up.
  # supervision_ready?/2 keeps the stricter meaning for convergence display.
  describe "advisory degradation versus supervision state" do
    test "a running add-on that reports an unenforceable host policy has still come up" do
      service = package(supervision: :systemd_service)

      status = %{
        state: "running",
        active: true,
        degradation_reason:
          "resource limits not enforced: enable parent controllers for addon cgroup root " <>
            "/sys/fs/cgroup/serviceradar.slice/serviceradar-addons.slice: required cgroup " <>
            "controller unavailable in /sys/fs/cgroup/serviceradar.slice: need cpu,memory,pids, " <>
            "available memory,pids"
      }

      assert Eligibility.supervision_state_ready?(service, status),
             "an undelegated cpu controller is a property of the host, not of the candidate"

      assert Eligibility.degraded?(status)
      refute Eligibility.supervision_ready?(service, status)
    end

    test "supervision state still requires the supervision model to be satisfied" do
      service = package(supervision: :systemd_service)

      refute Eligibility.supervision_state_ready?(service, %{
               state: "unhealthy",
               active: false,
               degradation_reason: "systemd unit failed"
             })

      refute Eligibility.supervision_state_ready?(service, %{
               state: "unhealthy",
               active: false,
               degradation_reason:
                 "dial netprobe socket: dial unix /run/serviceradar/netprobe/ipc.sock: " <>
                   "connect: connection refused"
             })
    end

    test "the agent's degraded state counts as having come up" do
      service = package(supervision: :systemd_service)
      timer = package(supervision: :systemd_timer)

      # powerdns's shape: the add-on returns HealthStatus::Degraded, and since
      # the agent now reports that distinctly instead of collapsing it into
      # "unhealthy", the rollout gate can see it came up.
      degraded = %{
        state: "degraded",
        active: true,
        degradation_reason: "no PowerDNS Recursor protobuf producer connected to 127.0.0.1:6000"
      }

      assert Eligibility.supervision_state_ready?(service, degraded)
      assert Eligibility.supervision_state_ready?(timer, degraded)

      # ...and it is still degraded, so convergence display still says so.
      refute Eligibility.supervision_ready?(service, degraded)
      assert Eligibility.degraded?(degraded)
    end

    test "supervision_ready? remains the stricter question for convergence display" do
      service = package(supervision: :systemd_service)
      clean = %{state: "running", active: true, degradation_reason: nil}

      assert Eligibility.supervision_ready?(service, clean)
      refute Eligibility.degraded?(clean)
    end
  end

  defp source do
    %{
      release_channel: "stable",
      capability_ceiling: ["network"],
      rollout_policy: %{}
    }
  end

  defp package(overrides) do
    values =
      Keyword.merge(
        [
          id: Ecto.UUID.generate(),
          addon_id: "netprobe",
          name: "Netprobe",
          version: "1.0.0",
          status: :approved,
          source_type: :first_party,
          source_oci_ref: "registry.example/netprobe:v1",
          source_oci_digest: "sha256:trusted",
          verification_status: "verified",
          verification_error: nil,
          approved_capabilities: ["network"],
          capabilities: ["network"],
          delivery: :pushed_artifact,
          supervision: :agent_sidecar,
          requires: %{"platforms" => ["linux"], "base_agent" => ">= 1.2.0"},
          artifacts: %{
            "linux/amd64" => %{"object_key" => "addons/netprobe", "sha256" => "abc"}
          }
        ],
        overrides
      )

    struct!(AddonPackage, values)
  end

  defp agent(now, overrides \\ []) do
    metadata = %{
      "os" => Keyword.get(overrides, :os, "linux"),
      "arch" => Keyword.get(overrides, :arch, "amd64")
    }

    metadata =
      case Keyword.fetch(overrides, :deployment_type) do
        {:ok, deployment_type} -> Map.put(metadata, "deployment_type", deployment_type)
        :error -> metadata
      end

    %{
      uid: "agent-1",
      version: "1.4.23",
      capabilities: Keyword.get(overrides, :capabilities, []),
      status: Keyword.get(overrides, :status, :connected),
      is_healthy: true,
      last_seen_time: now,
      metadata: metadata
    }
  end
end
