defmodule ServiceRadar.SweepJobs.SweepResultsFlowE2ETest do
  use ServiceRadar.DataCase, async: false

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
          agent_id: agent_id
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
          agent_id: agent_id
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
          agent_id: agent_id,
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
        %{name: "Sweep Duplicate Active IP #{unique_id}", partition: partition},
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
        %{name: "Sweep Restore Deleted #{unique_id}", partition: partition},
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
        %{name: "Sweep Changed IP #{unique_id}", partition: partition},
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
          agent_id: agent_id
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
          agent_id: agent_id,
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

    assert {:ok, _} =
             SweepResultsIngestor.ingest_results(
               [host_result],
               exec_a,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_a,
               config_version: "all-agents-a-#{unique_id}"
             )

    assert {:ok, _} =
             SweepResultsIngestor.ingest_results(
               [host_result],
               exec_b,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_b,
               config_version: "all-agents-b-#{unique_id}"
             )

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
  end

  defp single_result([result]), do: result
  defp single_result(result), do: result
end
