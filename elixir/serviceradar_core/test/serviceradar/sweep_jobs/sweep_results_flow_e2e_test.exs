defmodule ServiceRadar.SweepJobs.SweepResultsFlowE2ETest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:test)
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, actor: actor, agent_id: agent_id}
  end

  defp results_from(read_result) when is_list(read_result), do: read_result
  defp results_from(%{results: results}), do: results

  test "ingest results updates devices and execution stats", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    existing_ip = "10.1.0.#{rem(unique_id, 200) + 10}"
    new_ip = "10.1.1.#{rem(unique_id, 200) + 10}"
    partition = "partition-stats-#{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-#{unique_id}",
          ip: existing_ip,
          hostname: "existing-#{unique_id}",
          discovery_sources: ["netbox"],
          tags: %{},
          is_available: false
        },
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Group #{unique_id}",
          partition: partition,
          agent_id: agent_id
        },
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    execution_id = Ash.UUID.generate()

    results = [
      %{
        "host_ip" => existing_ip,
        "hostname" => "existing-#{unique_id}",
        "available" => true,
        "icmp_response_time_ns" => 1_200_000,
        "port_results" => [
          %{"port" => 22, "available" => true, "response_time" => 1_200_000},
          %{"port" => 443, "available" => true, "response_time" => 1_500_000}
        ],
        "last_sweep_time" => DateTime.to_iso8601(DateTime.utc_now())
      },
      %{
        "host_ip" => new_ip,
        "hostname" => "new-#{unique_id}",
        "available" => false,
        "port_results" => [],
        "error" => "timeout"
      }
    ]

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(results, execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-#{unique_id}"
             )

    assert stats.hosts_total == 2
    assert stats.hosts_available == 1
    assert stats.hosts_failed == 1
    assert stats.devices_created == 0
    assert stats.devices_updated == 1

    assert {:ok, existing_device_page} =
             Device
             |> Ash.Query.filter(ip == ^existing_ip)
             |> Ash.read(actor: actor)

    [existing_device] = existing_device_page.results

    assert existing_device.is_available
    assert "sweep" in existing_device.discovery_sources
    assert "netbox" in existing_device.discovery_sources

    assert {:ok, new_device_page} =
             Device
             |> Ash.Query.filter(ip == ^new_ip)
             |> Ash.read(actor: actor)

    assert new_device_page.results == []

    assert {:ok, host_results_page} =
             SweepHostResult
             |> Ash.Query.for_read(:by_execution, %{execution_id: execution_id})
             |> Ash.read(actor: actor)

    host_results = results_from(host_results_page)

    assert length(host_results) == 2

    assert Enum.any?(host_results, fn result ->
             result.ip == existing_ip and result.status == :available and
               result.open_ports == [22, 443]
           end)

    assert Enum.any?(host_results, fn result ->
             result.ip == new_ip and result.status in [:unavailable, :error]
           end)

    assert {:ok, execution_page} =
             SweepGroupExecution
             |> Ash.Query.filter(id == ^execution_id)
             |> Ash.read(actor: actor)

    [execution] = results_from(execution_page)

    assert execution.status == :completed
    assert execution.hosts_total == 2
    assert execution.hosts_available == 1
    assert execution.hosts_failed == 1
    assert execution.sweep_group_id == group.id
    assert execution.agent_id == agent_id
  end

  test "ingest results creates provisional devices for available unknown sweep hosts", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    new_ip = "10.2.1.#{rem(unique_id, 200) + 10}"
    partition = "partition-create-#{unique_id}"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Sweep Create #{unique_id}",
          partition: partition
        },
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    execution_id = Ash.UUID.generate()

    results = [
      %{
        "host_ip" => new_ip,
        "hostname" => "mikrotik-#{unique_id}",
        "available" => true,
        "icmp_response_time_ns" => 2_000_000,
        "port_results" => [
          %{"port" => 8291, "available" => true, "response_time" => 2_000_000}
        ]
      }
    ]

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(results, execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-create-#{unique_id}"
             )

    assert stats.hosts_total == 1
    assert stats.hosts_available == 1
    assert stats.hosts_failed == 0
    assert stats.devices_created == 1
    assert stats.devices_updated == 0

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip == ^new_ip)
             |> Ash.read(actor: actor)

    [device] = device_page.results

    assert device.hostname == "mikrotik-#{unique_id}"
    assert device.is_available
    assert "sweep" in device.discovery_sources
    assert device.metadata["identity_state"] == "provisional"
    assert device.metadata["identity_source"] == "sweep_ip_seed"

    assert {:ok, host_result_page} =
             SweepHostResult
             |> Ash.Query.for_read(:by_execution, %{execution_id: execution_id})
             |> Ash.read(actor: actor)

    [host_result] = results_from(host_result_page)

    assert host_result.ip == new_ip
    assert host_result.status == :available
    assert host_result.device_id == device.uid
    assert host_result.open_ports == [8291]
  end

  test "ingest results promotes available unknown hosts into mapper discovery", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    new_ip = "10.3.1.#{rem(unique_id, 200) + 10}"
    mapper_job_name = "mapper-promote-#{unique_id}"
    partition = "partition-promote-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Promote #{unique_id}", partition: partition, agent_id: agent_id},
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    {:ok, mapper_job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: mapper_job_name,
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    dispatcher = fn job, opts ->
      send(
        self(),
        {:mapper_dispatch, job.id, job.name, Keyword.get(opts, :seeds),
         Keyword.get(opts, :trigger_source)}
      )

      {:ok, "cmd-#{unique_id}"}
    end

    results = [
      %{
        "host_ip" => new_ip,
        "hostname" => "mikrotik-promote-#{unique_id}",
        "available" => true,
        "icmp_response_time_ns" => 2_000_000
      }
    ]

    execution_id = Ash.UUID.generate()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(results, execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-promote-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert stats.mapper_dispatched == 1
    assert stats.mapper_suppressed == 0
    assert stats.mapper_skipped == 0
    assert stats.mapper_failed == 0

    mapper_job_id = mapper_job.id
    assert_receive {:mapper_dispatch, ^mapper_job_id, ^mapper_job_name, [^new_ip], "sweep"}

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip == ^new_ip)
             |> Ash.read(actor: actor)

    [device] = device_page.results

    assert device.metadata["sweep_mapper_promotion"]["last_status"] == "dispatched"
    assert device.metadata["sweep_mapper_promotion"]["last_reason"] == "mapper_dispatched"
    assert device.metadata["sweep_mapper_promotion"]["mapper_job_id"] == mapper_job.id
    assert device.metadata["sweep_mapper_promotion"]["command_id"] == "cmd-#{unique_id}"
  end

  test "ingest results dispatches mapper promotion once across multiple ingest batches", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    ip_one = "10.3.2.#{rem(unique_id, 200) + 10}"
    ip_two = "10.3.3.#{rem(unique_id, 200) + 10}"
    mapper_job_name = "mapper-multibatch-#{unique_id}"
    partition = "partition-multibatch-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep MultiBatch #{unique_id}", partition: partition, agent_id: agent_id},
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    {:ok, mapper_job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: mapper_job_name,
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    dispatcher = fn job, opts ->
      send(
        self(),
        {:mapper_multibatch_dispatch, job.id, job.name, Enum.sort(Keyword.get(opts, :seeds, []))}
      )

      {:ok, "cmd-multibatch-#{unique_id}"}
    end

    filler_results =
      for idx <- 1..499 do
        %{
          "host_ip" => "10.3.200.#{idx}",
          "hostname" => "filler-#{unique_id}-#{idx}",
          "available" => false,
          "error" => "timeout"
        }
      end

    results =
      [
        %{
          "host_ip" => ip_one,
          "hostname" => "multibatch-one-#{unique_id}",
          "available" => true
        }
      ] ++
        filler_results ++
        [
          %{
            "host_ip" => ip_two,
            "hostname" => "multibatch-two-#{unique_id}",
            "available" => true
          }
        ]

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-multibatch-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert stats.mapper_dispatched == 1

    mapper_job_id = mapper_job.id

    assert_receive {:mapper_multibatch_dispatch, ^mapper_job_id, ^mapper_job_name, seeds}
    assert seeds == Enum.sort([ip_one, ip_two])
    refute_receive {:mapper_multibatch_dispatch, _, _, _}
  end

  test "ingest results suppresses duplicate mapper promotion during cooldown", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    ip = "10.4.1.#{rem(unique_id, 200) + 10}"
    mapper_job_name = "mapper-cooldown-#{unique_id}"
    partition = "partition-cooldown-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Cooldown #{unique_id}", partition: partition, agent_id: agent_id},
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    {:ok, _mapper_job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: mapper_job_name,
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    dispatcher = fn _job, opts ->
      send(self(), {:cooldown_dispatch, Keyword.get(opts, :seeds)})
      {:ok, "cmd-cooldown-#{unique_id}"}
    end

    results = [%{"host_ip" => ip, "available" => true}]

    assert {:ok, first_stats} =
             SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-cooldown-first-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert first_stats.mapper_dispatched == 1
    assert_receive {:cooldown_dispatch, [^ip]}

    assert {:ok, second_stats} =
             SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-cooldown-second-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert second_stats.mapper_dispatched == 0
    assert second_stats.mapper_suppressed == 1
    refute_receive {:cooldown_dispatch, _}
  end

  test "ingest results skips mapper promotion for the sweep agent's own managed device", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    ip = "10.4.2.#{rem(unique_id, 200) + 10}"
    partition = "partition-self-#{unique_id}"
    device_uid = "device-self-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: ip,
          hostname: "self-device-#{unique_id}",
          agent_id: agent_id,
          is_available: true,
          is_managed: true,
          is_trusted: true,
          discovery_sources: ["agent"]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Self #{unique_id}", partition: partition, agent_id: agent_id},
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    {:ok, _mapper_job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "mapper-self-#{unique_id}",
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "available" => true}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-self-#{unique_id}",
               mapper_promotion_opts: [
                 dispatcher: fn _job, _opts ->
                   send(self(), :unexpected_self_dispatch)
                   {:ok, "unexpected"}
                 end,
                 cooldown_seconds: 900
               ]
             )

    assert stats.mapper_dispatched == 0
    assert stats.mapper_skipped == 1
    refute_receive :unexpected_self_dispatch

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip == ^ip)
             |> Ash.read(actor: actor)

    [device] = device_page.results

    assert device.metadata["sweep_mapper_promotion"]["last_status"] == "skipped"
    assert device.metadata["sweep_mapper_promotion"]["last_reason"] == "sweep_agent_device"
  end

  test "ingest results records skipped promotion when no eligible mapper job exists", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    ip = "10.5.1.#{rem(unique_id, 200) + 10}"
    partition = "partition-skip-#{unique_id}"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Skip #{unique_id}", partition: partition, agent_id: agent_id},
        actor: actor,
        actor: actor
      )
      |> Ash.create()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "available" => true}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-skip-#{unique_id}",
               mapper_promotion_opts: [
                 dispatcher: fn _job, _opts ->
                   send(self(), :unexpected_dispatch)
                   {:ok, "unexpected"}
                 end
               ]
             )

    assert stats.mapper_dispatched == 0
    assert stats.mapper_skipped == 1
    refute_receive :unexpected_dispatch

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip == ^ip)
             |> Ash.read(actor: actor)

    [device] = device_page.results
    assert device.metadata["sweep_mapper_promotion"]["last_status"] == "skipped"
    assert device.metadata["sweep_mapper_promotion"]["last_reason"] == "no_eligible_mapper_job"
  end
end
