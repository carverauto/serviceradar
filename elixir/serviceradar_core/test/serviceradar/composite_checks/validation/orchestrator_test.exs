defmodule ServiceRadar.CompositeChecks.Validation.OrchestratorTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.CompositeChecks.Validation.Orchestrator
  alias ServiceRadar.CompositeChecks.ValidationRun
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Scans.ScanResult
  alias ServiceRadar.Scans.ScanRun
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  defp actor, do: SystemActor.system(:validation_orchestrator_test)

  defp unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"
  end

  defp create_device!(ip) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "orch-#{System.unique_integer([:positive])}",
        ip: ip
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp enabled_check!(agent_a, agent_b, opts \\ []) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Isolation #{System.unique_integer([:positive])}",
          scope_query: "in:devices"
        },
        actor: actor()
      )
      |> Ash.create()

    {:ok, alma} =
      CompositeCheckInput
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          key: "alma",
          label: "alma",
          position: 0,
          kind: :vantage_point,
          expected: "available",
          config: %{"agent_id" => agent_a, "max_age_seconds" => 5400}
        },
        actor: actor()
      )
      |> Ash.create()

    {:ok, k8s} =
      CompositeCheckInput
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          key: "k8s",
          label: "k8s",
          position: 1,
          kind: :vantage_point,
          expected: "blocked",
          config: %{"agent_id" => agent_b, "max_age_seconds" => 5400}
        },
        actor: actor()
      )
      |> Ash.create()

    inputs =
      if Keyword.get(opts, :with_fact, false) do
        {:ok, fact} =
          CompositeCheckInput
          |> Ash.Changeset.for_create(
            :create,
            %{
              check_id: check.id,
              key: "acl_enforced",
              label: "acl_enforced",
              position: 2,
              kind: :device_metadata,
              config: %{"path" => "acl_enforced", "value_type" => "boolean"}
            },
            actor: actor()
          )
          |> Ash.create()

        [alma, k8s, fact]
      else
        [alma, k8s]
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    {:ok, enabled} =
      check
      |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
      |> Ash.update()

    enabled
  end

  # SweepGroup validates agent_ids against registered agents, so a group's
  # scanners have to exist before the group does.
  defp register_agent!(uid) do
    case Agent.get_by_uid(uid, actor: actor()) do
      {:ok, _agent} ->
        :ok

      {:error, _reason} ->
        Agent
        |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor())
        |> Ash.create!()

        :ok
    end
  end

  defp covering_groups!(agent_a, agent_b) do
    profile =
      SweepProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "farm-scan-#{System.unique_integer([:positive])}",
          ports: [22, 80, 443, 8080],
          sweep_modes: ["icmp", "tcp", "arp"]
        },
        actor: actor()
      )
      |> Ash.create!()

    for agent_id <- [agent_a, agent_b] do
      register_agent!(agent_id)

      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "g-#{agent_id}-#{System.unique_integer([:positive])}",
          partition: "default",
          interval: "1h",
          agent_id: agent_id,
          target_query: "in:devices",
          profile_id: profile.id
        },
        actor: actor()
      )
      |> Ash.create!()
    end

    profile
  end

  test "start resolves IP to uid without dispatching probes" do
    ip = unique_ip()
    device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_b = "k8s-#{System.unique_integer([:positive])}"
    covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b)

    assert {:ok, run} =
             Orchestrator.start(%{"check" => check.slug, "ip" => ip, "partition" => "default"},
               actor: actor(),
               enqueue?: false
             )

    assert run.status == :pending
    assert [%{device_uid: uid, ip: ^ip}] = run.devices
    assert uid == device.uid
  end

  test "start rejects an unknown check" do
    ip = unique_ip()
    _ = create_device!(ip)

    assert {:error, :check_not_found} =
             Orchestrator.start(%{"check" => "no-such-check", "ip" => ip},
               actor: actor(),
               enqueue?: false
             )
  end

  test "advance dispatches compiled profile settings and never calls run_now" do
    ip = unique_ip()
    _device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_b = "k8s-#{System.unique_integer([:positive])}"
    profile = covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b)

    {:ok, run} =
      Orchestrator.start(%{"check" => check.slug, "ip" => ip},
        actor: actor(),
        enqueue?: false
      )

    test = self()

    dispatcher = fn agent_id, targets, opts ->
      send(test, {:dispatch, agent_id, targets, opts})

      {:ok, scan} =
        ScanRun.create(
          %{
            agent_id: agent_id,
            modes: opts[:modes],
            ports: opts[:ports] || [],
            targets: targets,
            target_count: length(targets)
          },
          actor: actor()
        )

      {:ok, _} =
        ScanRun.update_status(scan, %{status: :completed, finished_at: DateTime.utc_now()},
          actor: actor()
        )

      {:ok, scan.id}
    end

    assert {:ok, :continue} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)

    dispatches =
      for _ <- 1..2 do
        assert_receive {:dispatch, agent_id, targets, opts}, 1_000
        {agent_id, targets, opts}
      end

    agents = dispatches |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert agents == Enum.sort([agent_a, agent_b])

    Enum.each(dispatches, fn {_agent, targets, opts} ->
      assert targets == [ip]
      assert :icmp in opts[:modes]
      assert :tcp in opts[:modes]
      assert opts[:ports] == profile.ports
    end)

    refute_received {:dispatch, _, _, _}
  end

  test "uncovered vantages cannot pass using fresh background availability" do
    ip = unique_ip()
    device = create_device!(ip)
    agent_a = "agent-witness-#{System.unique_integer([:positive])}"
    agent_b = "agent-isolation-#{System.unique_integer([:positive])}"
    check = enabled_check!(agent_a, agent_b)

    for {agent, available?} <- [{agent_a, true}, {agent_b, false}] do
      DeviceAgentAvailability
      |> Ash.Changeset.for_create(:create, %{
        device_uid: device.uid,
        agent_id: agent,
        is_available: available?,
        checked_at: DateTime.utc_now()
      }, actor: actor())
      |> Ash.create!()
    end

    {:ok, run} = Orchestrator.start(%{"check" => check.slug, "ip" => ip}, actor: actor(), enqueue?: false)
    caller = self()
    dispatcher = fn _, _, _ -> send(caller, :unexpected_probe); {:error, :unexpected_probe} end

    assert {:ok, :completed} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)
    refute_received :unexpected_probe
    {:ok, completed} = ValidationRun.get_by_id(run.id, actor: actor())
    assert [%{verdict: "not_probed", verdict_status: :unknown} = result] = completed.devices
    assert result.inputs["alma"]["covered"] == false
    assert result.inputs["alma"]["probed"] == false
    assert result.inputs["alma"]["reason"] == "uncovered"
    assert result.inputs["k8s"]["observed_at"] == nil
    assert {:error, _} = DeviceCompositeCheckResult.get_by_device_check(device.uid, check.id, actor: actor())
  end

  test "a vantage with no covering group is not probed" do
    ip = unique_ip()
    _device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_narrow = "narrow-#{System.unique_integer([:positive])}"

    profile =
      SweepProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "farm-scan-#{System.unique_integer([:positive])}",
          ports: [22, 80, 443, 8080],
          sweep_modes: ["icmp", "tcp"]
        },
        actor: actor()
      )
      |> Ash.create!()

    register_agent!(agent_a)
    register_agent!(agent_narrow)

    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "g-#{agent_a}",
        partition: "default",
        interval: "1h",
        agent_id: agent_a,
        static_targets: ["10.0.0.0/8"],
        profile_id: profile.id
      },
      actor: actor()
    )
    |> Ash.create!()

    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "g-#{agent_narrow}",
        partition: "default",
        interval: "1h",
        agent_id: agent_narrow,
        target_query: "in:devices ip:172.16.0.0/12",
        profile_id: profile.id
      },
      actor: actor()
    )
    |> Ash.create!()

    check = enabled_check!(agent_a, agent_narrow)

    {:ok, run} =
      Orchestrator.start(%{"check" => check.slug, "ip" => ip},
        actor: actor(),
        enqueue?: false
      )

    test = self()

    dispatcher = fn agent_id, targets, opts ->
      send(test, {:dispatch, agent_id, targets, opts})

      {:ok, scan} =
        ScanRun.create(
          %{
            agent_id: agent_id,
            modes: opts[:modes],
            ports: opts[:ports] || [],
            targets: targets,
            target_count: length(targets)
          },
          actor: actor()
        )

      {:ok, scan.id}
    end

    assert {:ok, :continue} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)
    assert_receive {:dispatch, ^agent_a, [^ip], _opts}, 1_000
    refute_received {:dispatch, ^agent_narrow, _, _}

    {:ok, run} = ValidationRun.get_by_id(run.id, actor: actor())
    [device] = run.devices
    assert device.coverage[agent_narrow]["state"] == "uncovered"

    DeviceAgentAvailability
    |> Ash.Changeset.for_create(:create, %{
      device_uid: device.device_uid,
      agent_id: agent_narrow,
      is_available: false,
      checked_at: DateTime.utc_now()
    }, actor: actor())
    |> Ash.create!()

    {:ok, scan} = ScanRun.get(device.coverage[agent_a]["scan_id"], actor: actor())
    {:ok, _} = ScanRun.update_status(scan, %{status: :completed, hosts_up: 1, finished_at: DateTime.utc_now()}, actor: actor())
    assert {:ok, :completed} = Orchestrator.advance(run.id, actor: actor())
    {:ok, run} = ValidationRun.get_by_id(run.id, actor: actor())
    assert [%{verdict: "not_probed", verdict_status: :unknown} = result] = run.devices
    assert result.inputs["alma"]["covered"] == true
    assert result.inputs["alma"]["probed"] == true
    assert result.inputs["k8s"]["covered"] == false
    assert result.inputs["k8s"]["probed"] == false
  end

  test "deadline does not invent a passing official result" do
    ip = unique_ip()
    device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_b = "k8s-#{System.unique_integer([:positive])}"
    covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b)

    past =
      DateTime.utc_now()
      |> DateTime.shift(second: -1)
      |> DateTime.truncate(:microsecond)

    {:ok, run} =
      Orchestrator.start(%{"check" => check.slug, "ip" => ip},
        actor: actor(),
        enqueue?: false,
        deadline_at: past
      )

    assert {:ok, :timed_out} = Orchestrator.advance(run.id, actor: actor())

    {:ok, timed} = ValidationRun.get_by_id(run.id, actor: actor())
    assert timed.status == :timed_out
    assert [%{verdict: "inconclusive", error: "timed_out"}] = timed.devices

    assert {:error, _} =
             DeviceCompositeCheckResult.get_by_device_check(device.uid, check.id, actor: actor())
  end

  test "create facts commit before probes and evaluation reads the new fact" do
    ip = unique_ip()
    device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_b = "k8s-#{System.unique_integer([:positive])}"
    covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b, with_fact: true)

    device
    |> Ash.Changeset.for_update(:write_facts, %{facts: %{"acl_enforced" => false}}, actor: actor())
    |> Ash.update!()

    {:ok, run} =
      Orchestrator.start(%{"check" => check.slug, "ip" => ip, "facts" => %{"acl_enforced" => true}},
        actor: actor(),
        enqueue?: false
      )

    dispatcher = fn agent_id, targets, opts ->
      {:ok, written} = Device.get_by_uid(device.uid, actor: actor())
      assert written.metadata["acl_enforced"] == true
      assert written.metadata["__fact_provenance"]["acl_enforced"]["updated_at"]

      {:ok, scan} =
        ScanRun.create(
          %{
            agent_id: agent_id,
            modes: opts[:modes],
            ports: opts[:ports] || [],
            targets: targets,
            target_count: length(targets)
          },
          actor: actor()
        )

      available? = agent_id == agent_a

      {:ok, _} =
        ScanResult.create(
          %{
            id: Ecto.UUID.generate(),
            time: DateTime.utc_now(),
            scan_run_id: scan.id,
            agent_id: agent_id,
            target_ip: ip,
            mode: "icmp",
            available: available?
          },
          actor: actor()
        )

      {:ok, _} =
        ScanRun.update_status(scan, %{status: :completed, finished_at: DateTime.utc_now()},
          actor: actor()
        )

      {:ok, scan.id}
    end

    assert {:ok, :continue} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)
    assert {:ok, :completed} = Orchestrator.advance(run.id, actor: actor())

    {:ok, alma} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_a, actor: actor())

    {:ok, k8s} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_b, actor: actor())

    assert alma.is_available
    refute k8s.is_available

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check(device.uid, check.id, actor: actor())

    assert result.verdict == "isolated_verified"
    assert result.inputs["acl_enforced"]["value"] == "true"
    assert result.inputs["alma"]["probed"] == true
    assert result.inputs["k8s"]["probed"] == true
  end

  test "completed scans without result rows fall back to hosts_up" do
    ip = unique_ip()
    device = create_device!(ip)
    agent_a = "agent-alma-#{System.unique_integer([:positive])}"
    agent_b = "k8s-#{System.unique_integer([:positive])}"
    covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b)

    {:ok, run} =
      Orchestrator.start(%{"check" => check.slug, "ip" => ip},
        actor: actor(),
        enqueue?: false
      )

    dispatcher = fn agent_id, targets, opts ->
      {:ok, scan} =
        ScanRun.create(
          %{
            agent_id: agent_id,
            modes: opts[:modes],
            ports: opts[:ports] || [],
            targets: targets,
            target_count: length(targets)
          },
          actor: actor()
        )

      hosts_up = if agent_id == agent_a, do: 1, else: 0

      {:ok, _} =
        ScanRun.update_status(
          scan,
          %{status: :completed, finished_at: DateTime.utc_now(), hosts_up: hosts_up},
          actor: actor()
        )

      {:ok, scan.id}
    end

    assert {:ok, :continue} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)
    assert {:ok, :completed} = Orchestrator.advance(run.id, actor: actor())

    {:ok, alma} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_a, actor: actor())

    {:ok, k8s} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_b, actor: actor())

    assert alma.is_available
    refute k8s.is_available
  end

  test "failed scans cannot supply a blocked isolation witness" do
    ip = unique_ip()
    create_device!(ip)
    agent_a = "agent-witness-#{System.unique_integer([:positive])}"
    agent_b = "agent-isolation-#{System.unique_integer([:positive])}"
    covering_groups!(agent_a, agent_b)
    check = enabled_check!(agent_a, agent_b)
    {:ok, run} = Orchestrator.start(%{"check" => check.slug, "ip" => ip}, actor: actor(), enqueue?: false)

    dispatcher = fn agent, targets, opts ->
      {:ok, scan} = ScanRun.create(%{
        agent_id: agent, modes: opts[:modes], ports: opts[:ports], targets: targets, target_count: length(targets)
      }, actor: actor())
      status = if agent == agent_a, do: :completed, else: :failed
      {:ok, _} = ScanRun.update_status(scan, %{
        status: status, hosts_up: if(agent == agent_a, do: 1, else: 0), finished_at: DateTime.utc_now()
      }, actor: actor())
      {:ok, scan.id}
    end

    assert {:ok, :continue} = Orchestrator.advance(run.id, actor: actor(), dispatcher: dispatcher)
    assert {:ok, :completed} = Orchestrator.advance(run.id, actor: actor())
    {:ok, completed} = ValidationRun.get_by_id(run.id, actor: actor())
    assert [%{verdict: "not_probed", verdict_status: :unknown} = result] = completed.devices
    assert result.inputs["alma"]["probed"] == true
    assert result.inputs["k8s"]["covered"] == true
    assert result.inputs["k8s"]["probed"] == false
    assert result.inputs["k8s"]["reason"] == "scan_failed"
  end

  test "an invalid target fact rolls back every fact write and creates no run" do
    ip = unique_ip()
    device = create_device!(ip)
    ip2 = unique_ip()
    second = create_device!(ip2)
    check = enabled_check!("agent-witness-#{System.unique_integer([:positive])}", "agent-isolation-#{System.unique_integer([:positive])}")
    {:ok, before} = ValidationRun.list_recent(actor: actor())

    assert {:error, _} = Orchestrator.start(%{
      "check" => check.slug,
      "devices" => [
        %{"ip" => ip, "facts" => %{"acl_enforced" => true}},
        %{"ip" => ip2, "facts" => %{"acl_enforced" => %{"invalid" => true}}}
      ]
    }, actor: actor(), enqueue?: false)

    {:ok, unchanged} = Device.get_by_uid(device.uid, actor: actor())
    {:ok, unchanged_second} = Device.get_by_uid(second.uid, actor: actor())
    refute Map.has_key?(unchanged.metadata || %{}, "acl_enforced")
    refute Map.has_key?(unchanged_second.metadata || %{}, "acl_enforced")
    {:ok, after_runs} = ValidationRun.list_recent(actor: actor())
    assert Enum.map(after_runs, & &1.id) == Enum.map(before, & &1.id)
  end
end
