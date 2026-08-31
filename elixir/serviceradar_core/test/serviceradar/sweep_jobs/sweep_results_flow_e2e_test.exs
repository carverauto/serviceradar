defmodule ServiceRadar.SweepJobs.SweepResultsFlowE2ETest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ExUnit.CaptureLog
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.MapperPromotion
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
    agent_id = "agent-" <> Ash.UUID.generate()

    {:ok, actor: actor, agent_id: agent_id}
  end

  defp results_from(read_result) when is_list(read_result), do: read_result
  defp results_from(%{results: results}), do: results

  defp unique_ip(seed) when is_binary(seed) do
    <<second, third, fourth, _rest::binary>> = :crypto.hash(:sha256, seed)
    "10.#{1 + rem(second, 254)}.#{1 + rem(third, 254)}.#{1 + rem(fourth, 254)}"
  end

  test "ingest results updates devices and execution stats", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    existing_ip = unique_ip("stats-existing-#{unique_id}")
    new_ip = unique_ip("stats-new-#{unique_id}")
    partition = "default"

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
          agent_ids: []
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
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
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

    {:ok, reloaded_group} = Ash.get(SweepGroup, group.id, actor: actor)
    assert %DateTime{} = reloaded_group.last_run_at
  end

  test "records banner grab audit summary on the sweep execution version", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("banner-audit-#{unique_id}")
    request_id = "req-banner-audit-#{unique_id}"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Banner Audit #{unique_id}",
          partition: "default",
          agent_ids: []
        },
        actor: actor
      )
      |> Ash.create()

    execution_id = Ash.UUID.generate()

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => ip,
                   "hostname" => "banner-audit-#{unique_id}",
                   "available" => true,
                   "port_results" => [
                     %{"port" => 22, "available" => true, "response_time" => 1_000_000}
                   ]
                 }
               ],
               execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: "default",
               request_id: request_id,
               banner_grab_summary: %{
                 "sweep_banner_grab_probes_total" => 12,
                 "sweep_banner_grab_matches_total" => 5,
                 "sweep_banner_grab_empty_response_total" => 2,
                 "sweep_banner_grab_errors_total" => 1,
                 "sweep_banner_grab_connection_reset_total" => 3,
                 "sweep_banner_grab_timeout_total" => "4",
                 "sweep_banner_grab_bytes_received_total" => 4096.9,
                 "attacker_controlled_blob" => String.duplicate("x", 1024)
               }
             )

    assert {:ok, execution_page} =
             SweepGroupExecution
             |> Ash.Query.filter(id == ^execution_id)
             |> Ash.read(actor: actor)

    [execution] = results_from(execution_page)

    assert execution.banner_grab_summary["probe_count"] == 12
    assert execution.banner_grab_summary["banner_match_count"] == 5
    assert execution.banner_grab_summary["empty_response_count"] == 2
    assert execution.banner_grab_summary["error_count"] == 8
    assert execution.banner_grab_summary["total_bytes_received"] == 4096
    refute Map.has_key?(execution.banner_grab_summary["counters"], "attacker_controlled_blob")

    version =
      Repo.query!(
        """
        SELECT version_action_name, version_action_inputs, request_id
        FROM platform.sweep_group_execution_versions
        WHERE version_source_id = ($1::text)::uuid
          AND version_action_name = 'record_banner_grab_phase'
        ORDER BY version_inserted_at DESC
        LIMIT 1
        """,
        [execution_id]
      )

    assert [
             [
               "record_banner_grab_phase",
               %{"banner_grab_summary" => version_summary, "request_id" => ^request_id},
               ^request_id
             ]
           ] = version.rows

    assert version_summary["probe_count"] == 12
    assert version_summary["banner_match_count"] == 5
    assert version_summary["error_count"] == 8
    refute Map.has_key?(version_summary["counters"], "attacker_controlled_blob")
  end

  test "successful ICMP or TCP evidence updates device availability when aggregate is false", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    icmp_ip = unique_ip("aggregate-icmp-#{unique_id}")
    tcp_ip = unique_ip("aggregate-tcp-#{unique_id}")
    partition = "default"

    for {uid, ip} <- [{"device-icmp-#{unique_id}", icmp_ip}, {"device-tcp-#{unique_id}", tcp_ip}] do
      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: uid,
            ip: ip,
            hostname: uid,
            discovery_sources: ["armis"],
            is_available: false
          },
          actor: actor
        )
        |> Ash.create()
    end

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Aggregate Evidence #{unique_id}",
          partition: partition,
          agent_ids: []
        },
        actor: actor
      )
      |> Ash.create()

    execution_id = Ash.UUID.generate()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => icmp_ip,
                   "available" => false,
                   "icmp_status" => %{"available" => true, "round_trip" => 5_000_000},
                   "port_results" => [
                     %{"port" => 22, "available" => false, "response_time" => 0}
                   ]
                 },
                 %{
                   "host_ip" => tcp_ip,
                   "available" => false,
                   "icmp_status" => %{"available" => false, "round_trip" => 0},
                   "port_results" => [
                     %{"port" => 443, "available" => true, "response_time" => 1_000_000}
                   ]
                 }
               ],
               execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
               config_version: "hash-aggregate-#{unique_id}"
             )

    assert stats.hosts_available == 2
    assert stats.hosts_failed == 0

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip in ^[icmp_ip, tcp_ip])
             |> Ash.read(actor: actor)

    assert Enum.all?(device_page.results, & &1.is_available)

    assert {:ok, host_results_page} =
             SweepHostResult
             |> Ash.Query.for_read(:by_execution, %{execution_id: execution_id})
             |> Ash.read(actor: actor)

    assert Enum.all?(results_from(host_results_page), &(&1.status == :available))
  end

  test "ingest results records per-agent availability and honors selected canonical source", %{
    actor: actor
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("per-agent-#{unique_id}")
    primary_agent_id = "agent-primary-#{unique_id}"
    secondary_agent_id = "agent-secondary-#{unique_id}"

    {:ok, _primary_agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: primary_agent_id, name: "Primary"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _secondary_agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: secondary_agent_id, name: "Secondary"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Per Agent #{unique_id}", partition: "default"},
        actor: actor
      )
      |> Ash.create()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-per-agent-#{unique_id}",
          ip: ip,
          hostname: "per-agent-#{unique_id}",
          discovery_sources: ["armis"],
          is_available: false,
          availability_source_agent_id: primary_agent_id
        },
        actor: actor
      )
      |> Ash.create()

    secondary_execution_id = Ash.UUID.generate()

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => ip,
                   "available" => true,
                   "icmp_response_time_ns" => 6_000_000,
                   "port_results" => [%{"port" => 80, "available" => true}]
                 }
               ],
               secondary_execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: secondary_agent_id,
               authenticated_agent_id: secondary_agent_id,
               authenticated_partition_id: "default",
               config_version: "secondary-#{unique_id}"
             )

    {:ok, device_after_secondary} = Device.get_by_ip(ip, false, actor: actor)
    device_after_secondary = single_result(device_after_secondary)

    refute device_after_secondary.is_available

    {:ok, secondary_row} =
      DeviceAgentAvailability.get_by_device_agent(
        device_after_secondary.uid,
        secondary_agent_id,
        actor: actor
      )

    assert secondary_row.is_available
    assert secondary_row.agent_name == "Secondary"
    assert elem(secondary_row.checked_at.microsecond, 1) == 6
    assert secondary_row.response_time_ms == 6
    assert secondary_row.open_ports == [80]

    primary_execution_id = Ash.UUID.generate()

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => ip,
                   "available" => true,
                   "icmp_response_time_ns" => 4_000_000,
                   "port_results" => []
                 }
               ],
               primary_execution_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: primary_agent_id,
               authenticated_agent_id: primary_agent_id,
               authenticated_partition_id: "default",
               config_version: "primary-#{unique_id}"
             )

    {:ok, device_after_primary} = Device.get_by_ip(ip, false, actor: actor)
    device_after_primary = single_result(device_after_primary)

    assert device_after_primary.is_available

    {:ok, primary_row} =
      DeviceAgentAvailability.get_by_device_agent(device_after_primary.uid, primary_agent_id,
        actor: actor
      )

    assert primary_row.is_available
    assert primary_row.agent_name == "Primary"
    assert primary_row.response_time_ms == 4
  end

  test "failed sweeps mark canonical availability unavailable despite non-sweep last_seen_time",
       %{
         actor: actor,
         agent_id: agent_id
       } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("canonical-unavailable-#{unique_id}")
    device_uid = "device-canonical-unavailable-#{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: ip,
          hostname: "canonical-unavailable-#{unique_id}",
          discovery_sources: ["armis"],
          is_available: true,
          last_seen_time: ~U[2100-01-01 00:00:00Z],
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Canonical Unavailable #{unique_id}",
          partition: "default",
          agent_ids: [],
          interval: "1h"
        },
        actor: actor
      )
      |> Ash.create()

    failed_result = %{
      "host_ip" => ip,
      "available" => false,
      "port_results" => [],
      "icmp_status" => %{"available" => false}
    }

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results([failed_result], Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: "default",
               config_version: "first-failure-#{unique_id}"
             )

    {:ok, after_first_failure} = Device.get_by_ip(ip, false, actor: actor)
    after_first_failure = single_result(after_first_failure)

    assert after_first_failure.is_available
    assert after_first_failure.metadata["sweep_consecutive_failures"] == 1

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results([failed_result], Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: "default",
               config_version: "second-failure-#{unique_id}"
             )

    {:ok, after_second_failure} = Device.get_by_ip(ip, false, actor: actor)
    after_second_failure = single_result(after_second_failure)

    refute after_second_failure.is_available
    assert after_second_failure.metadata["sweep_consecutive_failures"] == 2

    {:ok, agent_row} =
      DeviceAgentAvailability.get_by_device_agent(device_uid, agent_id, actor: actor)

    refute agent_row.is_available
  end

  test "recent sweep success still wins over concurrent failed sweeps within interval", %{
    actor: actor
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("available-wins-#{unique_id}")
    primary_agent_id = "agent-available-wins-primary-#{unique_id}"
    secondary_agent_id = "agent-available-wins-secondary-#{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-available-wins-#{unique_id}",
          ip: ip,
          hostname: "available-wins-#{unique_id}",
          discovery_sources: ["sweep"],
          is_available: false,
          availability_source_agent_id: primary_agent_id,
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Available Wins #{unique_id}",
          partition: "default",
          interval: "1h"
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "available" => true, "port_results" => []}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: primary_agent_id,
               authenticated_agent_id: primary_agent_id,
               authenticated_partition_id: "default",
               config_version: "available-#{unique_id}"
             )

    failed_result = %{
      "host_ip" => ip,
      "available" => false,
      "port_results" => [],
      "icmp_status" => %{"available" => false}
    }

    for attempt <- 1..2 do
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results([failed_result], Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: secondary_agent_id,
                 authenticated_agent_id: secondary_agent_id,
                 authenticated_partition_id: "default",
                 config_version: "failed-#{attempt}-#{unique_id}"
               )
    end

    {:ok, device_after_failures} = Device.get_by_ip(ip, false, actor: actor)
    device_after_failures = single_result(device_after_failures)

    assert device_after_failures.is_available
    assert device_after_failures.metadata["sweep_consecutive_failures"] == 0
    assert is_binary(device_after_failures.metadata["sweep_last_available_at"])
  end

  test "per-agent availability prevents unreachable aliases from marking canonical device unavailable",
       %{
         actor: actor
       } do
    unique_id = Ash.UUID.generate()
    private_ip = unique_ip("per-agent-private-#{unique_id}")
    public_ip = unique_ip("per-agent-public-#{unique_id}")
    device_uid = "device-per-agent-availability-#{unique_id}"
    reachable_agent_id = "agent-reachable-#{unique_id}"
    unreachable_agent_id = "agent-unreachable-#{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: private_ip,
          hostname: "per-agent-availability-#{unique_id}",
          discovery_sources: ["sweep"],
          is_available: false,
          availability_source_agent_id: reachable_agent_id,
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, alias_state} =
      DeviceAliasState.create_detected(
        %{
          device_id: device_uid,
          partition: "default",
          alias_type: :ip,
          alias_value: public_ip,
          metadata: %{}
        },
        actor: actor
      )

    assert {:ok, _confirmed_alias} =
             DeviceAliasState.record_sighting(alias_state, %{confirm_threshold: 1}, actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Per-Agent Availability #{unique_id}",
          partition: "default",
          interval: "15m"
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, _stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => private_ip, "available" => true, "port_results" => []}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: reachable_agent_id,
               authenticated_agent_id: reachable_agent_id,
               authenticated_partition_id: "default",
               config_version: "available-#{unique_id}"
             )

    failed_result = %{
      "host_ip" => public_ip,
      "available" => false,
      "port_results" => [],
      "icmp_status" => %{"available" => false}
    }

    for attempt <- 1..2 do
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results([failed_result], Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: unreachable_agent_id,
                 authenticated_agent_id: unreachable_agent_id,
                 authenticated_partition_id: "default",
                 config_version: "failed-alias-#{attempt}-#{unique_id}"
               )
    end

    {:ok, device_after_failures} = Device.get_by_ip(private_ip, false, actor: actor)
    device_after_failures = single_result(device_after_failures)

    assert device_after_failures.is_available
    assert device_after_failures.metadata["sweep_consecutive_failures"] == 0

    {:ok, reachable_row} =
      DeviceAgentAvailability.get_by_device_agent(device_uid, reachable_agent_id, actor: actor)

    {:ok, unreachable_row} =
      DeviceAgentAvailability.get_by_device_agent(device_uid, unreachable_agent_id, actor: actor)

    assert reachable_row.is_available
    refute unreachable_row.is_available
  end

  test "ingest results creates provisional devices for available unknown sweep hosts", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    new_ip = unique_ip("create-#{unique_id}")
    partition = "default"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Sweep Create #{unique_id}",
          partition: partition,
          agent_ids: []
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
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
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

  test "ingest results resolves active device when cache contains stale duplicate IP record", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("duplicate-active-ip-#{unique_id}")
    partition = "default"

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-duplicate-active-ip-#{unique_id}",
          ip: ip,
          hostname: "authoritative-#{unique_id}",
          discovery_sources: ["armis"],
          is_available: false
        },
        actor: actor
      )
      |> Ash.create()

    IdentityCache.put(ip, %{
      canonical_device_id: "sr:stale-duplicate-active-ip-#{unique_id}",
      partition: partition,
      metadata_hash: nil,
      attributes: %{"ip" => ip, "partition" => partition},
      updated_at: DateTime.utc_now()
    })

    on_exit(fn -> IdentityCache.delete(ip) end)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Sweep Duplicate Active IP #{unique_id}",
          partition: partition,
          agent_ids: []
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "hostname" => "sweep-#{unique_id}", "available" => true}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
               config_version: "hash-duplicate-active-ip-#{unique_id}"
             )

    assert stats.devices_created == 0
    assert stats.devices_updated == 1

    assert {:ok, device_page} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(ip == ^ip)
             |> Ash.read(actor: actor)

    [resolved] = results_from(device_page)

    assert resolved.uid == device.uid
    assert resolved.is_available
    assert is_nil(resolved.deleted_at)
  end

  test "ingest results restores soft-deleted non-sweep device resolved by IP", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("restore-deleted-#{unique_id}")
    partition = "default"

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-restore-deleted-#{unique_id}",
          ip: ip,
          hostname: "deleted-#{unique_id}",
          discovery_sources: ["armis"],
          is_available: false
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, _deleted} =
             device
             |> Ash.Changeset.for_update(
               :soft_delete,
               %{deleted_reason: "test", deleted_by: "sweep_results_flow_e2e"},
               actor: actor
             )
             |> Ash.update()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Restore Deleted #{unique_id}", partition: partition, agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "hostname" => "restored-#{unique_id}", "available" => true}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
               config_version: "hash-restore-deleted-#{unique_id}"
             )

    assert stats.devices_created == 0
    assert stats.devices_updated == 1

    assert {:ok, restored_page} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^device.uid)
             |> Ash.read(actor: actor)

    [restored] = results_from(restored_page)

    assert is_nil(restored.deleted_at)
    assert is_nil(restored.deleted_by)
    assert is_nil(restored.deleted_reason)
    assert restored.is_available
  end

  test "ingest results ignores stale cache after active device IP changes", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    old_ip = unique_ip("changed-old-#{unique_id}")
    new_ip = unique_ip("changed-new-#{unique_id}")
    partition = "default"

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-changed-ip-#{unique_id}",
          ip: old_ip,
          hostname: "changed-ip-#{unique_id}",
          discovery_sources: ["netbox"],
          is_available: true
        },
        actor: actor
      )
      |> Ash.create()

    IdentityCache.put(old_ip, %{
      canonical_device_id: device.uid,
      partition: partition,
      metadata_hash: nil,
      attributes: %{"ip" => old_ip, "partition" => partition},
      updated_at: DateTime.utc_now()
    })

    on_exit(fn -> IdentityCache.delete(old_ip) end)

    assert {:ok, _updated} =
             device
             |> Ash.Changeset.for_update(:update, %{ip: new_ip}, actor: actor)
             |> Ash.update()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Changed IP #{unique_id}", partition: partition, agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => old_ip,
                   "hostname" => "new-host-at-old-ip-#{unique_id}",
                   "available" => true
                 }
               ],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
               config_version: "hash-changed-ip-#{unique_id}"
             )

    assert stats.devices_created == 1
    assert stats.devices_updated == 0

    assert {:ok, moved_page} =
             Device
             |> Ash.Query.filter(uid == ^device.uid)
             |> Ash.read(actor: actor)

    [moved_device] = results_from(moved_page)
    assert moved_device.ip == new_ip

    assert {:ok, old_ip_page} =
             Device
             |> Ash.Query.filter(ip == ^old_ip)
             |> Ash.read(actor: actor)

    [provisional] = results_from(old_ip_page)

    refute provisional.uid == device.uid
    assert provisional.metadata["identity_state"] == "provisional"
    assert provisional.metadata["identity_source"] == "sweep_ip_seed"
  end

  test "ingest results promotes available unknown hosts into mapper discovery", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    new_ip = unique_ip("promote-#{unique_id}")
    mapper_job_name = "mapper-promote-#{unique_id}"
    partition = "default"

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
               authenticated_agent_id: agent_id,
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

  test "ingest results ignores stale identity cache during mapper promotion", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    new_ip = unique_ip("stale-cache-#{unique_id}")
    mapper_job_name = "mapper-stale-cache-#{unique_id}"
    partition = "default"

    IdentityCache.put(new_ip, %{
      canonical_device_id: "sr:stale-cache-#{unique_id}",
      partition: partition,
      metadata_hash: nil,
      attributes: %{"ip" => new_ip, "partition" => partition},
      updated_at: DateTime.utc_now()
    })

    on_exit(fn -> IdentityCache.delete(new_ip) end)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Stale Cache #{unique_id}", partition: partition, agent_id: agent_id},
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
        {:stale_cache_dispatch, job.id, job.name, Keyword.get(opts, :seeds)}
      )

      {:ok, "cmd-stale-cache-#{unique_id}"}
    end

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [
                 %{
                   "host_ip" => new_ip,
                   "hostname" => "stale-cache-#{unique_id}",
                   "available" => true
                 }
               ],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               config_version: "hash-stale-cache-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert stats.devices_created == 1
    assert stats.mapper_dispatched == 1

    mapper_job_id = mapper_job.id
    assert_receive {:stale_cache_dispatch, ^mapper_job_id, ^mapper_job_name, [^new_ip]}

    assert {:ok, device_page} =
             Device
             |> Ash.Query.filter(ip == ^new_ip)
             |> Ash.read(actor: actor)

    [device] = device_page.results
    assert device.uid != "sr:stale-cache-#{unique_id}"
    assert device.metadata["sweep_mapper_promotion"]["last_status"] == "dispatched"

    assert device.metadata["sweep_mapper_promotion"]["command_id"] ==
             "cmd-stale-cache-#{unique_id}"
  end

  test "mapper promotion skips stale device map entries without metadata writes", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("stale-promotion-map-#{unique_id}")
    partition = "default"
    active_uid = "device-stale-promotion-active-#{unique_id}"
    stale_uid = "device-stale-promotion-stale-#{unique_id}"

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: active_uid,
          ip: ip,
          hostname: "active-owner-#{unique_id}",
          discovery_sources: ["armis"],
          metadata: %{},
          is_available: true
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Sweep Stale Promotion Map #{unique_id}",
          partition: partition,
          agent_ids: []
        },
        actor: actor
      )
      |> Ash.create()

    stats =
      MapperPromotion.promote(
        [%{"host_ip" => ip, "available" => true}],
        %{ip => %{canonical_device_id: stale_uid}},
        group.id,
        agent_id,
        actor: actor,
        dispatcher: fn _job, _opts ->
          send(self(), :unexpected_stale_promotion_dispatch)
          {:ok, "unexpected"}
        end
      )

    assert stats.dispatched == 0
    assert stats.skipped == 1
    refute_receive :unexpected_stale_promotion_dispatch

    assert {:ok, reloaded} = Ash.get(Device, device.uid, actor: actor)
    refute Map.has_key?(reloaded.metadata || %{}, "sweep_mapper_promotion")
  end

  test "ingest results dispatches mapper promotion once across multiple ingest batches", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip_one = unique_ip("multibatch-one-#{unique_id}")
    ip_two = unique_ip("multibatch-two-#{unique_id}")
    mapper_job_name = "mapper-multibatch-#{unique_id}"
    partition = "default"

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
               authenticated_agent_id: agent_id,
               config_version: "hash-multibatch-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert stats.mapper_dispatched == 1

    mapper_job_id = mapper_job.id

    assert_receive {:mapper_multibatch_dispatch, ^mapper_job_id, ^mapper_job_name, seeds}
    assert seeds == Enum.sort([ip_one, ip_two])
    refute_receive {:mapper_multibatch_dispatch, _, _, _}
  end

  test "ingest results updates only the sweep group's partition copy of an IP", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("isolation-#{unique_id}")
    isolation_partition = "rids-#{unique_id}"

    {:ok, monitoring} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-monitoring-#{unique_id}",
          ip: ip,
          partition: "default",
          hostname: "monitoring-#{unique_id}",
          discovery_sources: ["sweep"],
          is_available: true
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, isolation} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-isolation-#{unique_id}",
          ip: ip,
          partition: isolation_partition,
          hostname: "isolation-#{unique_id}",
          discovery_sources: ["manual"],
          is_available: true
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Isolation Sweep #{unique_id}",
          partition: isolation_partition,
          agent_ids: [],
          interval: "15m",
          static_targets: [ip]
        },
        actor: actor
      )
      |> Ash.create()

    # Marking a device unavailable requires @unavailable_threshold (2) consecutive
    # failed sweeps; one failure only increments the counter. Sweep twice so this
    # test asserts partition isolation rather than tripping over hysteresis.
    for attempt <- 1..2 do
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results(
                 [
                   %{
                     "host_ip" => ip,
                     "available" => false,
                     "icmp_status" => %{"available" => false}
                   }
                 ],
                 Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 authenticated_partition_id: isolation_partition,
                 config_version: "hash-isolation-#{attempt}-#{unique_id}"
               )
    end

    {:ok, monitoring_after} = Device.get_by_uid(monitoring.uid, false, actor: actor)
    {:ok, isolation_after} = Device.get_by_uid(isolation.uid, false, actor: actor)

    assert monitoring_after.is_available
    refute isolation_after.is_available
  end

  test "ingest results suppresses duplicate mapper promotion during cooldown", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("cooldown-#{unique_id}")
    mapper_job_name = "mapper-cooldown-#{unique_id}"
    partition = "default"

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
               authenticated_agent_id: agent_id,
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
               authenticated_agent_id: agent_id,
               config_version: "hash-cooldown-second-#{unique_id}",
               mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
             )

    assert second_stats.mapper_dispatched == 0
    assert second_stats.mapper_suppressed == 1
    refute_receive {:cooldown_dispatch, _}
  end

  test "ingest results suppresses mapper promotion while mapper job interval is still active", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("interval-#{unique_id}")
    mapper_job_name = "mapper-interval-#{unique_id}"
    partition = "default"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: agent_id}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Interval #{unique_id}", partition: partition, agent_id: agent_id},
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
          interval: "5m",
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _updated_job} =
      mapper_job
      |> Ash.Changeset.for_update(
        :record_run,
        %{last_run_at: DateTime.truncate(DateTime.utc_now(), :second), last_run_status: :success}
      )
      |> Ash.update(actor: actor)

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(
               [%{"host_ip" => ip, "available" => true}],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               authenticated_agent_id: agent_id,
               config_version: "hash-interval-#{unique_id}",
               mapper_promotion_opts: [
                 dispatcher: fn _job, _opts ->
                   send(self(), :unexpected_interval_dispatch)
                   {:ok, "unexpected"}
                 end
               ]
             )

    assert stats.mapper_dispatched == 0
    assert stats.mapper_suppressed == 1
    refute_receive :unexpected_interval_dispatch
  end

  test "ingest results skips mapper promotion for the sweep agent's own managed device", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("self-#{unique_id}")
    partition = "default"
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
               authenticated_agent_id: agent_id,
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
    unique_id = Ash.UUID.generate()
    ip = unique_ip("skip-#{unique_id}")
    partition = "default"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Sweep Skip #{unique_id}", partition: partition, agent_ids: []},
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
               authenticated_agent_id: agent_id,
               authenticated_partition_id: partition,
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

  test "an All-agents group records availability from every reporting scanner", %{
    actor: actor
  } do
    unique_id = Ash.UUID.generate()
    ip = unique_ip("all-agents-#{unique_id}")
    agent_a = "agent-a-#{unique_id}"
    agent_b = "agent-b-#{unique_id}"

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-all-agents-#{unique_id}",
          ip: ip,
          partition: "default",
          hostname: "all-agents-#{unique_id}",
          discovery_sources: ["manual"],
          is_available: false
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "All Agents Sweep #{unique_id}",
          partition: "default",
          agent_id: nil,
          interval: "15m",
          static_targets: [ip],
          sweep_modes: ["icmp"]
        },
        actor: actor
      )
      |> Ash.create()

    exec_a = Ash.UUID.generate()
    exec_b = Ash.UUID.generate()

    host_result = %{
      "host_ip" => ip,
      "available" => true,
      "icmp_status" => %{"available" => true}
    }

    conflict_log =
      CaptureLog.capture_log(fn ->
        assert {:ok, _} =
                 SweepResultsIngestor.ingest_results(
                   [host_result],
                   exec_a,
                   actor: actor,
                   sweep_group_id: group.id,
                   agent_id: agent_a,
                   authenticated_agent_id: agent_a,
                   authenticated_partition_id: "default",
                   config_version: "all-agents-a-#{unique_id}"
                 )

        assert {:ok, _} =
                 SweepResultsIngestor.ingest_results(
                   [host_result],
                   exec_b,
                   actor: actor,
                   sweep_group_id: group.id,
                   agent_id: agent_b,
                   authenticated_agent_id: agent_b,
                   authenticated_partition_id: "default",
                   config_version: "all-agents-b-#{unique_id}"
                 )
      end)

    refute conflict_log =~ "MULTI-AGENT CONFLICT"

    {:ok, execution_page} =
      SweepGroupExecution
      |> Ash.Query.filter(sweep_group_id == ^group.id)
      |> Ash.read(actor: actor)

    executions = results_from(execution_page)

    assert MapSet.new(Enum.map(executions, & &1.agent_id)) == MapSet.new([agent_a, agent_b])
    assert Enum.all?(executions, &(&1.status == :completed))
    assert Enum.all?(executions, &(&1.hosts_available == 1))

    {:ok, daa_a} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_a, actor: actor)

    {:ok, daa_b} =
      DeviceAgentAvailability.get_by_device_agent(device.uid, agent_b, actor: actor)

    assert daa_a.is_available
    assert daa_a.sweep_group_id == group.id
    assert daa_a.execution_id == exec_a
    assert daa_b.is_available
    assert daa_b.sweep_group_id == group.id
    assert daa_b.execution_id == exec_b

    {:ok, canonical} = Device.get_by_uid(device.uid, false, actor: actor)
    canonical = single_result(canonical)
    assert canonical.is_available

    assert {:ok, pinned} =
             canonical
             |> Ash.Changeset.for_update(
               :set_availability_source,
               %{availability_source_agent_id: agent_a},
               actor: actor
             )
             |> Ash.update()

    assert {:ok, _} =
             SweepResultsIngestor.ingest_results(
               [host_result],
               Ash.UUID.generate(),
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_a,
               authenticated_agent_id: agent_a,
               authenticated_partition_id: "default",
               config_version: "all-agents-a-pinned-#{unique_id}"
             )

    {:ok, after_pin} = Device.get_by_uid(pinned.uid, false, actor: actor)
    after_pin = single_result(after_pin)
    assert after_pin.is_available
    assert after_pin.availability_source_agent_id == agent_a
  end

  describe "persisted reporter expectation" do
    test "selected reporters are independent and a deselected reporter remains forensic", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_a = "expected-a-#{unique_id}"
      agent_b = "expected-b-#{unique_id}"
      agent_c = "unexpected-c-#{unique_id}"

      Enum.each([agent_a, agent_b, agent_c], &register_reporter!(actor, &1))

      device = reporter_device!(actor, unique_id, "independent", false)
      group = reporter_group!(actor, unique_id, "independent", [agent_a, agent_b])
      result = available_result(device.ip)

      expected_log =
        CaptureLog.capture_log(fn ->
          assert {:ok, _} = ingest_report(actor, group.id, agent_a, result)
          assert {:ok, _} = ingest_report(actor, group.id, agent_b, result)
        end)

      refute expected_log =~ "ANOMALOUS SWEEP ASSIGNMENT"
      refute expected_log =~ "MULTI-AGENT CONFLICT"

      assert {:ok, group_after_expected} = Ash.get(SweepGroup, group.id, actor: actor)
      assert group_after_expected.last_run_at

      historical_last_run = ~U[2020-01-02 03:04:05Z]

      {1, _} =
        Repo.update_all(
          from(g in SweepGroup, where: g.id == ^group.id),
          set: [last_run_at: historical_last_run]
        )

      unexpected_log =
        CaptureLog.capture_log(fn ->
          assert {:ok, _} = ingest_report(actor, group.id, agent_c, result)
        end)

      assert unexpected_log =~ "ANOMALOUS SWEEP ASSIGNMENT"
      assert unexpected_log =~ group.id
      assert unexpected_log =~ agent_c

      assert {:ok, group_after_unexpected} = Ash.get(SweepGroup, group.id, actor: actor)
      assert group_after_unexpected.last_run_at == historical_last_run

      {:ok, execution_page} =
        SweepGroupExecution
        |> Ash.Query.filter(sweep_group_id == ^group.id)
        |> Ash.read(actor: actor)

      assert MapSet.new(Enum.map(results_from(execution_page), & &1.agent_id)) ==
               MapSet.new([agent_a, agent_b, agent_c])

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_c, actor: actor)

      assert forensic_row.is_available
      assert forensic_row.sweep_group_id == group.id
      assert forensic_row.metadata["sweep_reporter_expectation"] == "unexpected"
      assert forensic_row.metadata["sweep_resolved_group_id"] == group.id
    end

    test "an unexpected reporter cannot make a newly discovered device canonically available", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      expected_agent = "expected-discovery-#{unique_id}"
      unexpected_agent = "unexpected-discovery-#{unique_id}"
      Enum.each([expected_agent, unexpected_agent], &register_reporter!(actor, &1))

      ip = unique_ip("unexpected-discovery-#{unique_id}")
      group = reporter_group!(actor, unique_id, "unexpected-discovery", [expected_agent])

      assert {:ok, _} =
               ingest_report(actor, group.id, unexpected_agent, available_result(ip))

      assert {:ok, device_page} =
               Device
               |> Ash.Query.filter(ip == ^ip and partition == "default")
               |> Ash.read(actor: actor)

      [device] = results_from(device_page)
      refute device.is_available

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, unexpected_agent,
                 actor: actor
               )

      assert forensic_row.is_available
      assert forensic_row.metadata["sweep_reporter_expectation"] == "unexpected"
    end

    test "All accepts an authenticated reporter while unattributed reporters fail closed", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      all_agent_id = "unregistered-partition-reporter-#{unique_id}"
      selected_agent_id = "selected-reporter-#{unique_id}"
      register_reporter!(actor, selected_agent_id)

      all_device = reporter_device!(actor, unique_id, "all-authenticated", false)
      all_group = reporter_group!(actor, unique_id, "all-authenticated", [])

      assert {:ok, _} =
               ingest_report(actor, all_group.id, all_agent_id, available_result(all_device.ip))

      assert reload_device!(actor, all_device.uid).is_available

      assert {:ok, all_row} =
               DeviceAgentAvailability.get_by_device_agent(all_device.uid, all_agent_id,
                 actor: actor
               )

      assert all_row.metadata["sweep_reporter_expectation"] == "expected"

      unknown_device =
        reporter_device!(actor, unique_id, "headerless", false,
          availability_source_agent_id: selected_agent_id
        )

      selected_group = reporter_group!(actor, unique_id, "headerless", [selected_agent_id])

      assert {:error, :conflicting_execution_reporter} =
               SweepResultsIngestor.ingest_results(
                 [available_result(unknown_device.ip)],
                 Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: selected_group.id,
                 agent_id: selected_agent_id,
                 config_version: "headerless-#{unique_id}"
               )

      refute reload_device!(actor, unknown_device.uid).is_available

      assert {:ok, unknown_row} =
               DeviceAgentAvailability.get_by_device_agent(unknown_device.uid, selected_agent_id,
                 actor: actor
               )

      assert unknown_row.metadata["sweep_reporter_expectation"] == "unknown"
      assert unknown_row.metadata["sweep_resolved_group_id"] == selected_group.id

      blank_device = reporter_device!(actor, unique_id, "blank-auth", false)

      assert {:error, :conflicting_execution_reporter} =
               SweepResultsIngestor.ingest_results(
                 [available_result(blank_device.ip)],
                 Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: selected_group.id,
                 agent_id: selected_agent_id,
                 authenticated_agent_id: "  ",
                 config_version: "blank-auth-#{unique_id}"
               )

      refute reload_device!(actor, blank_device.uid).is_available

      assert {:ok, blank_row} =
               DeviceAgentAvailability.get_by_device_agent(blank_device.uid, selected_agent_id,
                 actor: actor
               )

      assert blank_row.metadata["sweep_reporter_expectation"] == "unknown"

      assert {:ok, selected_group_after_unknown} =
               Ash.get(SweepGroup, selected_group.id, actor: actor)

      assert is_nil(selected_group_after_unknown.last_run_at)
    end

    test "All keeps a cross-partition authenticated reporter forensic-only", %{actor: actor} do
      unique_id = Ash.UUID.generate()
      reporter_agent_id = "cross-partition-all-reporter-#{unique_id}"

      device = reporter_device!(actor, unique_id, "cross-partition-all", false)
      group = reporter_group!(actor, unique_id, "cross-partition-all", [])

      log =
        CaptureLog.capture_log(fn ->
          assert {:ok, _} =
                   ingest_report(
                     actor,
                     group.id,
                     reporter_agent_id,
                     available_result(device.ip),
                     authenticated_partition_id: "other-partition"
                   )
        end)

      assert log =~ "ANOMALOUS SWEEP ASSIGNMENT"
      assert log =~ group.id
      assert log =~ reporter_agent_id
      refute reload_device!(actor, device.uid).is_available

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, reporter_agent_id,
                 actor: actor
               )

      assert forensic_row.is_available
      assert forensic_row.sweep_group_id == group.id
      assert forensic_row.metadata["sweep_reporter_expectation"] == "unexpected"
      assert forensic_row.metadata["sweep_resolved_group_id"] == group.id

      assert {:ok, group_after_report} = Ash.get(SweepGroup, group.id, actor: actor)
      assert is_nil(group_after_report.last_run_at)
    end

    test "All keeps reporters without a canonical authenticated partition forensic-only", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      group = reporter_group!(actor, unique_id, "missing-authenticated-partition", [])

      for {suffix, partition_opts} <- [
            {"missing", []},
            {"blank", [authenticated_partition_id: "  "]}
          ] do
        reporter_agent_id = "#{suffix}-partition-all-reporter-#{unique_id}"
        device = reporter_device!(actor, unique_id, "#{suffix}-partition-all", false)
        execution_id = Ash.UUID.generate()

        opts =
          Keyword.merge(
            [
              actor: actor,
              sweep_group_id: group.id,
              agent_id: reporter_agent_id,
              authenticated_agent_id: reporter_agent_id,
              config_version: "#{suffix}-partition-#{unique_id}"
            ],
            partition_opts
          )

        assert {:ok, _} =
                 SweepResultsIngestor.ingest_results(
                   [available_result(device.ip)],
                   execution_id,
                   opts
                 )

        refute reload_device!(actor, device.uid).is_available

        assert {:ok, forensic_row} =
                 DeviceAgentAvailability.get_by_device_agent(device.uid, reporter_agent_id,
                   actor: actor
                 )

        assert forensic_row.is_available
        assert forensic_row.metadata["sweep_reporter_expectation"] == "unknown"
        assert forensic_row.metadata["sweep_resolved_group_id"] == group.id
      end

      assert {:ok, group_after_reports} = Ash.get(SweepGroup, group.id, actor: actor)
      assert is_nil(group_after_reports.last_run_at)
    end

    test "unknown reporters cannot supersede running group executions", %{actor: actor} do
      unique_id = Ash.UUID.generate()
      claimed_agent = "supersede-claimed-#{unique_id}"
      other_agent = "supersede-other-#{unique_id}"
      Enum.each([claimed_agent, other_agent], &register_reporter!(actor, &1))

      group = reporter_group!(actor, unique_id, "unknown-supersession", [claimed_agent])
      claimed_execution = running_execution!(actor, group.id, claimed_agent)
      other_execution = running_execution!(actor, group.id, other_agent)

      assert {:error, :conflicting_execution_reporter} =
               SweepResultsIngestor.ingest_results([], Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: claimed_agent,
                 config_version: "body-only-#{unique_id}"
               )

      assert Repo.get!(SweepGroupExecution, claimed_execution.id).status == :running
      assert Repo.get!(SweepGroupExecution, other_execution.id).status == :running

      assert {:error, :conflicting_execution_reporter} =
               SweepResultsIngestor.ingest_results([], Ash.UUID.generate(),
                 actor: actor,
                 sweep_group_id: group.id,
                 config_version: "unattributed-#{unique_id}"
               )

      assert Repo.get!(SweepGroupExecution, claimed_execution.id).status == :running
      assert Repo.get!(SweepGroupExecution, other_execution.id).status == :running
    end

    test "unknown reports retain forensic anchors without inventory or mapper side effects", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      claimed_agent = "unknown-side-effects-#{unique_id}"
      register_reporter!(actor, claimed_agent)

      alias_ip = unique_ip("unknown-alias-#{unique_id}")
      deleted_ip = unique_ip("unknown-deleted-#{unique_id}")
      provisional_ip = unique_ip("unknown-provisional-#{unique_id}")

      alias_device = reporter_device!(actor, unique_id, "unknown-alias", false)

      deleted_device =
        reporter_device!(actor, unique_id, "unknown-deleted", false, ip: deleted_ip)

      assert {:ok, alias_state} =
               DeviceAliasState.create_detected(
                 %{
                   device_id: alias_device.uid,
                   partition: "default",
                   alias_type: :ip,
                   alias_value: alias_ip,
                   metadata: %{}
                 },
                 actor: actor
               )

      assert {:ok, _deleted} =
               deleted_device
               |> Ash.Changeset.for_update(
                 :soft_delete,
                 %{deleted_reason: "unknown reporter test", deleted_by: "task-6-review"},
                 actor: actor
               )
               |> Ash.update(actor: actor)

      deleted_before = include_deleted_device!(actor, deleted_device.uid)
      assert %DateTime{} = deleted_before.deleted_at

      group = reporter_group!(actor, unique_id, "unknown-side-effects", [claimed_agent])

      assert {:ok, mapper_job} =
               MapperJob
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Unknown reporter mapper #{unique_id}",
                   partition: "default",
                   discovery_mode: :snmp,
                   discovery_type: :full
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)

      test_pid = self()

      dispatcher = fn job, opts ->
        send(test_pid, {:unknown_reporter_mapper_dispatch, job.id, Keyword.get(opts, :seeds)})
        {:ok, "unknown-reporter-command-#{unique_id}"}
      end

      execution_id = Ash.UUID.generate()

      assert {:error, :conflicting_execution_reporter} =
               SweepResultsIngestor.ingest_results(
                 Enum.map([alias_ip, deleted_ip, provisional_ip], &available_result/1),
                 execution_id,
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: claimed_agent,
                 config_version: "unknown-side-effects-#{unique_id}",
                 mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
               )

      assert {:ok, alias_after} = Ash.get(DeviceAliasState, alias_state.id, actor: actor)
      deleted_after = include_deleted_device!(actor, deleted_device.uid)

      assert {:ok, provisional_page} =
               Device
               |> Ash.Query.filter(ip == ^provisional_ip and partition == "default")
               |> Ash.read(actor: actor)

      [provisional] = results_from(provisional_page)
      alias_device_after = reload_device!(actor, alias_device.uid)

      forensic_uids = [alias_device.uid, deleted_device.uid, provisional.uid]

      forensic_rows =
        Repo.all(
          from(a in DeviceAgentAvailability,
            where: a.agent_id == ^claimed_agent and a.device_uid in ^forensic_uids,
            select: {a.device_uid, a.execution_id, a.metadata}
          )
        )

      assert %{
               alias_state: alias_after.state,
               alias_sightings: alias_after.sighting_count,
               alias_sources: alias_device_after.discovery_sources,
               alias_mapper_metadata?:
                 Map.has_key?(alias_device_after.metadata || %{}, "sweep_mapper_promotion"),
               deleted_at: deleted_before.deleted_at,
               deleted_sources: deleted_after.discovery_sources,
               deleted_mapper_metadata?:
                 Map.has_key?(deleted_after.metadata || %{}, "sweep_mapper_promotion"),
               provisional_available: provisional.is_available,
               provisional_mapper_metadata?:
                 Map.has_key?(provisional.metadata || %{}, "sweep_mapper_promotion"),
               execution: Repo.get(SweepGroupExecution, execution_id),
               host_result_count: length(host_result_snapshots(actor, execution_id)),
               audit_count: execution_audit_count(execution_id),
               forensic_rows:
                 forensic_rows
                 |> Enum.map(fn {uid, row_execution_id, metadata} ->
                   {uid, row_execution_id, metadata["sweep_reporter_expectation"]}
                 end)
                 |> Enum.sort()
             } == %{
               alias_state: :detected,
               alias_sightings: 1,
               alias_sources: ["manual"],
               alias_mapper_metadata?: false,
               deleted_at: deleted_after.deleted_at,
               deleted_sources: ["manual"],
               deleted_mapper_metadata?: false,
               provisional_available: false,
               provisional_mapper_metadata?: false,
               execution: nil,
               host_result_count: 0,
               audit_count: 0,
               forensic_rows:
                 forensic_uids
                 |> Enum.map(&{&1, nil, "unknown"})
                 |> Enum.sort()
             }

      assert %DateTime{} = deleted_after.deleted_at
      mapper_job_id = mapper_job.id
      refute_receive {:unknown_reporter_mapper_dispatch, ^mapper_job_id, _seeds}
    end

    test "an unexpected reporter mutates only its explicitly configured availability device", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      expected_agent = "unexpected-side-effects-expected-#{unique_id}"
      unexpected_agent = "unexpected-side-effects-reporter-#{unique_id}"
      Enum.each([expected_agent, unexpected_agent], &register_reporter!(actor, &1))

      alias_ip = unique_ip("unexpected-alias-#{unique_id}")
      unconfigured_ip = unique_ip("unexpected-unconfigured-#{unique_id}")
      configured_ip = unique_ip("unexpected-configured-#{unique_id}")

      alias_device = reporter_device!(actor, unique_id, "unexpected-alias", false)

      unconfigured_device =
        reporter_device!(actor, unique_id, "unexpected-unconfigured", false, ip: unconfigured_ip)

      configured_device =
        reporter_device!(actor, unique_id, "unexpected-configured", false,
          ip: configured_ip,
          availability_source_agent_id: unexpected_agent
        )

      assert {:ok, alias_state} =
               DeviceAliasState.create_detected(
                 %{
                   device_id: alias_device.uid,
                   partition: "default",
                   alias_type: :ip,
                   alias_value: alias_ip,
                   metadata: %{}
                 },
                 actor: actor
               )

      Enum.each([unconfigured_device, configured_device], fn device ->
        assert {:ok, _deleted} =
                 device
                 |> Ash.Changeset.for_update(
                   :soft_delete,
                   %{deleted_reason: "unexpected reporter test", deleted_by: "task-6-review"},
                   actor: actor
                 )
                 |> Ash.update(actor: actor)
      end)

      unconfigured_deleted_at = include_deleted_device!(actor, unconfigured_device.uid).deleted_at
      assert %DateTime{} = unconfigured_deleted_at
      assert %DateTime{} = include_deleted_device!(actor, configured_device.uid).deleted_at

      group =
        reporter_group!(actor, unique_id, "unexpected-side-effects", [expected_agent])

      assert {:ok, mapper_job} =
               MapperJob
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Unexpected reporter mapper #{unique_id}",
                   partition: "default",
                   discovery_mode: :snmp,
                   discovery_type: :full
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)

      test_pid = self()

      dispatcher = fn job, opts ->
        send(test_pid, {:unexpected_reporter_mapper_dispatch, job.id, Keyword.get(opts, :seeds)})
        {:ok, "unexpected-reporter-command-#{unique_id}"}
      end

      execution_id = Ash.UUID.generate()

      assert {:ok, stats} =
               SweepResultsIngestor.ingest_results(
                 Enum.map([alias_ip, unconfigured_ip, configured_ip], &available_result/1),
                 execution_id,
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: unexpected_agent,
                 authenticated_agent_id: unexpected_agent,
                 config_version: "unexpected-side-effects-#{unique_id}",
                 mapper_promotion_opts: [dispatcher: dispatcher, cooldown_seconds: 900]
               )

      assert {:ok, alias_after} = Ash.get(DeviceAliasState, alias_state.id, actor: actor)
      alias_device_after = reload_device!(actor, alias_device.uid)
      unconfigured_after = include_deleted_device!(actor, unconfigured_device.uid)
      configured_after = include_deleted_device!(actor, configured_device.uid)

      assert {:ok, configured_forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(
                 configured_device.uid,
                 unexpected_agent,
                 actor: actor
               )

      assert %{
               alias_state: alias_after.state,
               alias_sightings: alias_after.sighting_count,
               alias_sources: alias_device_after.discovery_sources,
               alias_available: alias_device_after.is_available,
               alias_mapper_metadata?:
                 Map.has_key?(alias_device_after.metadata || %{}, "sweep_mapper_promotion"),
               unconfigured_deleted_at: unconfigured_after.deleted_at,
               unconfigured_sources: unconfigured_after.discovery_sources,
               unconfigured_mapper_metadata?:
                 Map.has_key?(unconfigured_after.metadata || %{}, "sweep_mapper_promotion"),
               configured_deleted_at: configured_after.deleted_at,
               configured_sources: Enum.sort(configured_after.discovery_sources),
               configured_available: configured_after.is_available,
               configured_mapper_metadata?:
                 Map.has_key?(configured_after.metadata || %{}, "sweep_mapper_promotion"),
               forensic_expectation:
                 configured_forensic_row.metadata["sweep_reporter_expectation"],
               host_result_count: length(host_result_snapshots(actor, execution_id)),
               mapper_stats:
                 Map.take(stats, [
                   :mapper_dispatched,
                   :mapper_failed,
                   :mapper_skipped,
                   :mapper_suppressed
                 ])
             } == %{
               alias_state: :detected,
               alias_sightings: 1,
               alias_sources: ["manual"],
               alias_available: false,
               alias_mapper_metadata?: false,
               unconfigured_deleted_at: unconfigured_deleted_at,
               unconfigured_sources: ["manual"],
               unconfigured_mapper_metadata?: false,
               configured_deleted_at: nil,
               configured_sources: ["manual", "sweep"],
               configured_available: true,
               configured_mapper_metadata?: false,
               forensic_expectation: "unexpected",
               host_result_count: 3,
               mapper_stats: %{
                 mapper_dispatched: 0,
                 mapper_failed: 0,
                 mapper_skipped: 0,
                 mapper_suppressed: 0
               }
             }

      mapper_job_id = mapper_job.id
      refute_receive {:unexpected_reporter_mapper_dispatch, ^mapper_job_id, _seeds}
    end

    test "missing or unresolved group identity fails closed", %{actor: actor} do
      unique_id = Ash.UUID.generate()
      agent_id = "missing-group-#{unique_id}"
      device = reporter_device!(actor, unique_id, "missing-group", false)
      result = available_result(device.ip)

      assert {:error, :missing_sweep_group_id} =
               SweepResultsIngestor.ingest_results(
                 [result],
                 Ash.UUID.generate(),
                 actor: actor,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 config_version: "missing-group-#{unique_id}"
               )

      unresolved_execution_id = Ash.UUID.generate()

      assert {:error, :unresolved_sweep_group} =
               SweepResultsIngestor.ingest_results(
                 [result],
                 unresolved_execution_id,
                 actor: actor,
                 sweep_group_id: Ash.UUID.generate(),
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 config_version: "unresolved-group-#{unique_id}"
               )

      refute reload_device!(actor, device.uid).is_available
      assert is_nil(Repo.get(SweepGroupExecution, unresolved_execution_id))

      assert is_nil(
               Repo.get_by(DeviceAgentAvailability, device_uid: device.uid, agent_id: agent_id)
             )
    end

    test "authenticated identity controls classification when a payload identity differs", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      selected_agent = "selected-auth-#{unique_id}"
      unexpected_agent = "unexpected-auth-#{unique_id}"
      Enum.each([selected_agent, unexpected_agent], &register_reporter!(actor, &1))

      unexpected_device = reporter_device!(actor, unique_id, "auth-unexpected", false)
      expected_device = reporter_device!(actor, unique_id, "auth-expected", false)
      group = reporter_group!(actor, unique_id, "identity-mismatch", [selected_agent])

      unexpected_log =
        CaptureLog.capture_log(fn ->
          assert {:ok, _} =
                   SweepResultsIngestor.ingest_results(
                     [available_result(unexpected_device.ip)],
                     Ash.UUID.generate(),
                     actor: actor,
                     sweep_group_id: group.id,
                     agent_id: selected_agent,
                     authenticated_agent_id: unexpected_agent,
                     config_version: "auth-unexpected-#{unique_id}"
                   )
        end)

      assert unexpected_log =~ "SWEEP REPORTER IDENTITY MISMATCH"
      refute reload_device!(actor, unexpected_device.uid).is_available

      assert {:ok, unexpected_row} =
               DeviceAgentAvailability.get_by_device_agent(
                 unexpected_device.uid,
                 unexpected_agent,
                 actor: actor
               )

      assert unexpected_row.metadata["sweep_reporter_expectation"] == "unexpected"
      assert unexpected_row.metadata["sweep_reported_agent_id"] == selected_agent

      expected_log =
        CaptureLog.capture_log(fn ->
          assert {:ok, _} =
                   SweepResultsIngestor.ingest_results(
                     [available_result(expected_device.ip)],
                     Ash.UUID.generate(),
                     actor: actor,
                     sweep_group_id: group.id,
                     agent_id: unexpected_agent,
                     authenticated_agent_id: selected_agent,
                     config_version: "auth-expected-#{unique_id}"
                   )
        end)

      assert expected_log =~ "SWEEP REPORTER IDENTITY MISMATCH"
      assert reload_device!(actor, expected_device.uid).is_available

      assert {:ok, expected_row} =
               DeviceAgentAvailability.get_by_device_agent(
                 expected_device.uid,
                 selected_agent,
                 actor: actor
               )

      assert expected_row.metadata["sweep_reporter_expectation"] == "expected"
      assert expected_row.metadata["sweep_reported_agent_id"] == unexpected_agent
    end

    test "an unexpected positive cannot block later expected failures", %{actor: actor} do
      unique_id = Ash.UUID.generate()
      expected_agent = "expected-failure-#{unique_id}"
      unexpected_agent = "unexpected-positive-#{unique_id}"

      Enum.each([expected_agent, unexpected_agent], &register_reporter!(actor, &1))

      device = reporter_device!(actor, unique_id, "unexpected-positive", true)
      group = reporter_group!(actor, unique_id, "unexpected-positive", [expected_agent])

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 unexpected_agent,
                 available_result(device.ip)
               )

      assert {:ok, unexpected_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, unexpected_agent,
                 actor: actor
               )

      assert unexpected_row.is_available
      assert unexpected_row.metadata["sweep_reporter_expectation"] == "unexpected"

      failed_result = unavailable_result(device.ip)

      assert {:ok, _} = ingest_report(actor, group.id, expected_agent, failed_result)
      assert {:ok, _} = ingest_report(actor, group.id, expected_agent, failed_result)

      refute reload_device!(actor, device.uid).is_available
    end

    test "an explicitly configured source wins even when it is outside the assignment", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      selected_agent = "selected-#{unique_id}"
      configured_agent = "configured-outside-#{unique_id}"

      Enum.each([selected_agent, configured_agent], &register_reporter!(actor, &1))

      device =
        reporter_device!(actor, unique_id, "configured-source", false,
          availability_source_agent_id: configured_agent
        )

      group = reporter_group!(actor, unique_id, "configured-source", [selected_agent])

      assert {:ok, _} =
               ingest_report(actor, group.id, configured_agent, available_result(device.ip))

      assert reload_device!(actor, device.uid).is_available

      assert {:ok, configured_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, configured_agent,
                 actor: actor
               )

      assert configured_row.metadata["sweep_reporter_expectation"] == "unexpected"

      assert {:ok, _} =
               ingest_report(actor, group.id, selected_agent, unavailable_result(device.ip))

      assert {:ok, _} =
               ingest_report(actor, group.id, selected_agent, unavailable_result(device.ip))

      assert reload_device!(actor, device.uid).is_available
    end

    test "the execution FK is authoritative when a later payload names another group", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_id = "execution-owner-#{unique_id}"
      register_reporter!(actor, agent_id)

      device = reporter_device!(actor, unique_id, "execution-owner", false)
      execution_group = reporter_group!(actor, unique_id, "execution-group", [agent_id])
      conflicting_group = reporter_group!(actor, unique_id, "payload-group", [agent_id])
      execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               ingest_report(
                 actor,
                 execution_group.id,
                 agent_id,
                 unavailable_result(device.ip),
                 execution_id: execution_id
               )

      assert {:ok, _} =
               ingest_report(
                 actor,
                 conflicting_group.id,
                 agent_id,
                 available_result(device.ip),
                 execution_id: execution_id
               )

      refute reload_device!(actor, device.uid).is_available

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_id, actor: actor)

      assert row.sweep_group_id == execution_group.id
      assert row.metadata["sweep_reporter_expectation"] == "unknown"
      assert row.metadata["sweep_resolved_group_id"] == execution_group.id
    end

    test "an authenticated reporter cannot reuse another reporter's execution", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_a = "execution-agent-a-#{unique_id}"
      agent_b = "execution-agent-b-#{unique_id}"
      Enum.each([agent_a, agent_b], &register_reporter!(actor, &1))

      device_a = reporter_device!(actor, unique_id, "execution-agent-a", false)
      device_b = reporter_device!(actor, unique_id, "execution-agent-b", false)
      group = reporter_group!(actor, unique_id, "execution-agent-owner", [agent_a, agent_b])
      execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               SweepResultsIngestor.ingest_results(
                 [available_result(device_a.ip)],
                 execution_id,
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: agent_a,
                 authenticated_agent_id: agent_a,
                 config_version: "execution-agent-a-#{unique_id}",
                 request_id: "request-a-#{unique_id}",
                 banner_grab_summary: %{"sweep_banner_grab_probes_total" => 1}
               )

      execution_before = execution_snapshot(execution_id)
      host_results_before = host_result_snapshots(actor, execution_id)
      audit_count_before = execution_audit_count(execution_id)

      result =
        SweepResultsIngestor.ingest_results(
          [available_result(device_b.ip)],
          execution_id,
          actor: actor,
          sweep_group_id: group.id,
          agent_id: agent_b,
          authenticated_agent_id: agent_b,
          config_version: "execution-agent-b-#{unique_id}",
          request_id: "request-b-#{unique_id}",
          banner_grab_summary: %{"sweep_banner_grab_probes_total" => 99}
        )

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(device_b.uid, agent_b, actor: actor)

      assert %{
               result: result,
               forensic_execution_id: forensic_row.execution_id,
               forensic_expectation: forensic_row.metadata["sweep_reporter_expectation"],
               canonical_available: reload_device!(actor, device_b.uid).is_available,
               execution: execution_snapshot(execution_id),
               host_results: host_result_snapshots(actor, execution_id),
               audit_count: execution_audit_count(execution_id)
             } == %{
               result: {:error, :conflicting_execution_reporter},
               forensic_execution_id: nil,
               forensic_expectation: "unknown",
               canonical_available: false,
               execution: execution_before,
               host_results: host_results_before,
               audit_count: audit_count_before
             }
    end

    test "a body-only claim cannot reuse an authenticated reporter's execution", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_id = "execution-body-only-#{unique_id}"
      register_reporter!(actor, agent_id)

      owner_device = reporter_device!(actor, unique_id, "execution-body-owner", false)
      forensic_device = reporter_device!(actor, unique_id, "execution-body-forensic", false)
      group = reporter_group!(actor, unique_id, "execution-body-only", [agent_id])
      execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               SweepResultsIngestor.ingest_results(
                 [available_result(owner_device.ip)],
                 execution_id,
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 config_version: "execution-body-owner-#{unique_id}",
                 request_id: "request-owner-#{unique_id}",
                 banner_grab_summary: %{"sweep_banner_grab_probes_total" => 1}
               )

      execution_before = execution_snapshot(execution_id)
      host_results_before = host_result_snapshots(actor, execution_id)
      audit_count_before = execution_audit_count(execution_id)

      result =
        SweepResultsIngestor.ingest_results(
          [available_result(forensic_device.ip)],
          execution_id,
          actor: actor,
          sweep_group_id: group.id,
          agent_id: agent_id,
          config_version: "execution-body-forensic-#{unique_id}",
          request_id: "request-forensic-#{unique_id}",
          banner_grab_summary: %{"sweep_banner_grab_probes_total" => 99}
        )

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(
                 forensic_device.uid,
                 agent_id,
                 actor: actor
               )

      assert %{
               result: result,
               forensic_execution_id: forensic_row.execution_id,
               forensic_expectation: forensic_row.metadata["sweep_reporter_expectation"],
               canonical_available: reload_device!(actor, forensic_device.uid).is_available,
               execution: execution_snapshot(execution_id),
               host_results: host_result_snapshots(actor, execution_id),
               audit_count: execution_audit_count(execution_id)
             } == %{
               result: {:error, :conflicting_execution_reporter},
               forensic_execution_id: nil,
               forensic_expectation: "unknown",
               canonical_available: false,
               execution: execution_before,
               host_results: host_results_before,
               audit_count: audit_count_before
             }
    end

    test "a body-only claim cannot create an execution before an authenticated retry", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_id = "execution-body-first-#{unique_id}"
      register_reporter!(actor, agent_id)

      device = reporter_device!(actor, unique_id, "execution-body-first", false)
      group = reporter_group!(actor, unique_id, "execution-body-first", [agent_id])
      execution_id = Ash.UUID.generate()

      result =
        SweepResultsIngestor.ingest_results(
          [available_result(device.ip)],
          execution_id,
          actor: actor,
          sweep_group_id: group.id,
          agent_id: agent_id,
          config_version: "execution-body-first-#{unique_id}",
          request_id: "request-body-first-#{unique_id}",
          scanner_metrics: %{"duration_ms" => 99},
          banner_grab_summary: %{"sweep_banner_grab_probes_total" => 99}
        )

      assert {:ok, forensic_row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_id, actor: actor)

      assert %{
               result: result,
               forensic_execution_id: forensic_row.execution_id,
               forensic_expectation: forensic_row.metadata["sweep_reporter_expectation"],
               canonical_available: reload_device!(actor, device.uid).is_available,
               execution: Repo.get(SweepGroupExecution, execution_id),
               host_results: host_result_snapshots(actor, execution_id),
               audit_count: execution_audit_count(execution_id)
             } == %{
               result: {:error, :conflicting_execution_reporter},
               forensic_execution_id: nil,
               forensic_expectation: "unknown",
               canonical_available: false,
               execution: nil,
               host_results: [],
               audit_count: 0
             }

      assert {:ok, _} =
               SweepResultsIngestor.ingest_results(
                 [available_result(device.ip)],
                 execution_id,
                 actor: actor,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 config_version: "execution-authenticated-retry-#{unique_id}"
               )

      assert %{agent_id: ^agent_id, sweep_group_id: group_id} =
               execution_snapshot(execution_id)

      assert group_id == group.id
      assert [_host_result] = host_result_snapshots(actor, execution_id)
      assert reload_device!(actor, device.uid).is_available
    end

    test "an existing execution resolves an omitted direct group identity", %{actor: actor} do
      unique_id = Ash.UUID.generate()
      agent_id = "execution-redelivery-#{unique_id}"
      register_reporter!(actor, agent_id)

      device = reporter_device!(actor, unique_id, "execution-redelivery", false)
      group = reporter_group!(actor, unique_id, "execution-redelivery", [agent_id])
      execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 agent_id,
                 unavailable_result(device.ip),
                 execution_id: execution_id
               )

      assert {:ok, _} =
               SweepResultsIngestor.ingest_results(
                 [available_result(device.ip)],
                 execution_id,
                 actor: actor,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 config_version: "execution-redelivery-#{unique_id}"
               )

      assert reload_device!(actor, device.uid).is_available

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_id, actor: actor)

      assert row.sweep_group_id == group.id
      assert row.metadata["sweep_resolved_group_id"] == group.id
      assert row.metadata["sweep_reporter_expectation"] == "expected"
    end

    test "an older unexpected result cannot replace a newer expected observation", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      original_agent = "fresh-original-#{unique_id}"
      replacement_agent = "fresh-replacement-#{unique_id}"
      Enum.each([original_agent, replacement_agent], &register_reporter!(actor, &1))

      device = reporter_device!(actor, unique_id, "freshness", false)
      group = reporter_group!(actor, unique_id, "freshness", [original_agent])
      newer = DateTime.truncate(DateTime.utc_now(), :microsecond)
      older = DateTime.add(newer, -3_600, :second)

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 original_agent,
                 available_result(device.ip, newer)
               )

      assert {:ok, group} =
               group
               |> Ash.Changeset.for_update(:update, %{agent_ids: [replacement_agent]},
                 actor: actor
               )
               |> Ash.update(actor: actor)

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 original_agent,
                 unavailable_result(device.ip, older)
               )

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, original_agent,
                 actor: actor
               )

      assert row.checked_at == newer
      assert row.is_available
      assert row.metadata["sweep_reporter_expectation"] == "expected"
    end

    test "an older expected positive cannot change canonical state or emit recovery", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      agent_id = "stale-expected-#{unique_id}"
      register_reporter!(actor, agent_id)

      device = reporter_device!(actor, unique_id, "stale-expected", true)

      group =
        reporter_group!(actor, unique_id, "stale-expected", [agent_id], %{
          emit_availability_events: true
        })

      newer = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.truncate(:microsecond)
      older = DateTime.add(newer, -3_600, :second)

      assert {:ok, _} =
               ingest_report(actor, group.id, agent_id, unavailable_result(device.ip, newer))

      assert {:ok, _} =
               ingest_report(actor, group.id, agent_id, unavailable_result(device.ip, newer))

      before_stale = reload_device!(actor, device.uid)
      refute before_stale.is_available
      assert before_stale.metadata["sweep_consecutive_failures"] == 2

      stale_execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               ingest_report(actor, group.id, agent_id, available_result(device.ip, older),
                 execution_id: stale_execution_id
               )

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_id, actor: actor)

      assert row.checked_at == newer
      refute row.is_available
      assert row.metadata["sweep_reporter_expectation"] == "expected"

      after_stale = reload_device!(actor, device.uid)
      refute after_stale.is_available
      assert after_stale.metadata["sweep_consecutive_failures"] == 2

      assert after_stale.metadata["sweep_last_available_at"] ==
               before_stale.metadata["sweep_last_available_at"]

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM logs WHERE (attributes::jsonb)->>'execution_id' = $1",
                 [stale_execution_id]
               )
    end

    test "an older configured-source positive cannot change canonical state or emit recovery", %{
      actor: actor
    } do
      unique_id = Ash.UUID.generate()
      selected_agent = "stale-selected-#{unique_id}"
      configured_agent = "stale-configured-#{unique_id}"
      Enum.each([selected_agent, configured_agent], &register_reporter!(actor, &1))

      device =
        reporter_device!(actor, unique_id, "stale-configured", true,
          availability_source_agent_id: configured_agent
        )

      group =
        reporter_group!(actor, unique_id, "stale-configured", [selected_agent], %{
          emit_availability_events: true
        })

      newer = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.truncate(:microsecond)
      older = DateTime.add(newer, -3_600, :second)

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 configured_agent,
                 unavailable_result(device.ip, newer)
               )

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 configured_agent,
                 unavailable_result(device.ip, newer)
               )

      before_stale = reload_device!(actor, device.uid)
      refute before_stale.is_available
      assert before_stale.metadata["sweep_consecutive_failures"] == 2

      stale_execution_id = Ash.UUID.generate()

      assert {:ok, _} =
               ingest_report(
                 actor,
                 group.id,
                 configured_agent,
                 available_result(device.ip, older),
                 execution_id: stale_execution_id
               )

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, configured_agent,
                 actor: actor
               )

      assert row.checked_at == newer
      refute row.is_available
      assert row.metadata["sweep_reporter_expectation"] == "unexpected"

      after_stale = reload_device!(actor, device.uid)
      refute after_stale.is_available
      assert after_stale.metadata["sweep_consecutive_failures"] == 2

      assert after_stale.metadata["sweep_last_available_at"] ==
               before_stale.metadata["sweep_last_available_at"]

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM logs WHERE (attributes::jsonb)->>'execution_id' = $1",
                 [stale_execution_id]
               )
    end
  end

  describe "canonical availability ownership across redelivery" do
    setup do
      unique_id = System.unique_integer([:positive])
      actor = SystemActor.system(:sweep_results_ingestor)

      %{unique_id: unique_id, actor: actor, agent_id: "agent-guard-#{unique_id}"}
    end

    test "a batch whose payload lost its group id resolves the group from the execution",
         %{unique_id: unique_id, actor: actor, agent_id: agent_id} do
      # A redelivery or later chunk can lose the direct group ID. The persisted
      # execution FK remains authoritative for reporter expectation and policy.
      ip = "10.90.#{rem(unique_id, 200) + 1}.#{rem(unique_id, 200) + 1}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "guard-#{unique_id}",
            ip: ip,
            hostname: "guard-#{unique_id}",
            discovery_sources: ["netbox"],
            tags: %{},
            is_available: true
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{name: "AllAgents #{unique_id}", partition: "default", agent_ids: []},
          actor: actor
        )
        |> Ash.create()

      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host_ip" => ip,
          "hostname" => "guard-#{unique_id}",
          "available" => false,
          "last_sweep_time" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]

      # First pass carries the group id and creates the execution.
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results(results, execution_id,
                 sweep_group_id: group.id,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 authenticated_partition_id: "default",
                 config_version: "hash-#{unique_id}"
               )

      # Second pass drops it, as a redelivery would.
      assert {:ok, _stats} =
               SweepResultsIngestor.ingest_results(results, execution_id,
                 sweep_group_id: nil,
                 agent_id: agent_id,
                 authenticated_agent_id: agent_id,
                 authenticated_partition_id: "default",
                 config_version: "hash-#{unique_id}"
               )

      {:ok, reloaded} = Ash.get(Device, device.uid, actor: actor)

      refute reloaded.is_available
      assert reloaded.metadata["sweep_consecutive_failures"] == 2

      assert {:ok, row} =
               DeviceAgentAvailability.get_by_device_agent(device.uid, agent_id, actor: actor)

      assert row.metadata["sweep_reporter_expectation"] == "expected"
      assert row.metadata["sweep_resolved_group_id"] == group.id
    end
  end

  defp register_reporter!(actor, agent_id) do
    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(:register, %{uid: agent_id, name: agent_id},
               actor: actor
             )
             |> Ash.create(actor: actor)
  end

  defp reporter_device!(actor, unique_id, suffix, available?, attrs \\ []) do
    ip = unique_ip("reporter-#{suffix}-#{unique_id}")

    base_attrs = %{
      uid: "device-reporter-#{suffix}-#{unique_id}",
      ip: ip,
      partition: "default",
      hostname: "reporter-#{suffix}-#{unique_id}",
      discovery_sources: ["manual"],
      is_available: available?,
      metadata: %{}
    }

    assert {:ok, device} =
             Device
             |> Ash.Changeset.for_create(:create, Map.merge(base_attrs, Map.new(attrs)),
               actor: actor
             )
             |> Ash.create(actor: actor)

    device
  end

  defp reporter_group!(actor, unique_id, suffix, agent_ids, attrs \\ %{}) do
    group_attrs =
      Map.merge(
        %{
          name: "Reporter #{suffix} #{unique_id}",
          partition: "default",
          agent_ids: agent_ids,
          interval: "1h"
        },
        attrs
      )

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               group_attrs,
               actor: actor
             )
             |> Ash.create(actor: actor)

    group
  end

  defp ingest_report(actor, group_id, agent_id, result, opts \\ []) do
    execution_id = Keyword.get(opts, :execution_id, Ash.UUID.generate())
    authenticated_partition_id = Keyword.get(opts, :authenticated_partition_id, "default")

    SweepResultsIngestor.ingest_results([result], execution_id,
      actor: actor,
      sweep_group_id: group_id,
      agent_id: agent_id,
      authenticated_agent_id: agent_id,
      authenticated_partition_id: authenticated_partition_id,
      config_version: "reporter-policy-#{execution_id}"
    )
  end

  defp available_result(ip, checked_at \\ DateTime.utc_now()) do
    %{
      "host_ip" => ip,
      "available" => true,
      "icmp_status" => %{"available" => true},
      "last_sweep_time" => DateTime.to_iso8601(checked_at)
    }
  end

  defp unavailable_result(ip, checked_at \\ DateTime.utc_now()) do
    %{
      "host_ip" => ip,
      "available" => false,
      "icmp_status" => %{"available" => false},
      "port_results" => [],
      "last_sweep_time" => DateTime.to_iso8601(checked_at)
    }
  end

  defp reload_device!(actor, uid) do
    assert {:ok, device} = Device.get_by_uid(uid, false, actor: actor)
    single_result(device)
  end

  defp include_deleted_device!(actor, uid) do
    assert {:ok, page} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: true})
             |> Ash.Query.filter(uid == ^uid)
             |> Ash.read(actor: actor)

    [device] = results_from(page)
    device
  end

  defp single_result([result]), do: result
  defp single_result(result), do: result

  defp execution_snapshot(execution_id) do
    execution = Repo.get!(SweepGroupExecution, execution_id)

    Map.take(execution, [
      :id,
      :agent_id,
      :sweep_group_id,
      :status,
      :started_at,
      :completed_at,
      :duration_ms,
      :hosts_total,
      :hosts_available,
      :hosts_failed,
      :error_message,
      :config_version,
      :scanner_metrics,
      :banner_grab_summary,
      :inserted_at,
      :updated_at
    ])
  end

  defp host_result_snapshots(actor, execution_id) do
    assert {:ok, page} =
             SweepHostResult
             |> Ash.Query.for_read(:by_execution, %{execution_id: execution_id})
             |> Ash.read(actor: actor)

    page
    |> results_from()
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :ip,
        :hostname,
        :status,
        :response_time_ms,
        :open_ports,
        :error_message,
        :device_id
      ])
    )
  end

  defp execution_audit_count(execution_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM platform.sweep_group_execution_versions
        WHERE version_source_id = ($1::text)::uuid
        """,
        [execution_id]
      )

    count
  end

  defp running_execution!(actor, sweep_group_id, agent_id) do
    assert {:ok, execution} =
             SweepGroupExecution
             |> Ash.Changeset.for_create(
               :start,
               %{
                 sweep_group_id: sweep_group_id,
                 agent_id: agent_id,
                 config_version: "running-#{Ash.UUID.generate()}"
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    execution
  end
end
