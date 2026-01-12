defmodule ServiceRadar.SweepJobs.SweepResultsFlowE2ETest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Inventory.Device

  alias ServiceRadar.SweepJobs.{
    SweepGroup,
    SweepGroupExecution,
    SweepHostResult,
    SweepResultsIngestor
  }

  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    %{tenant_id: tenant_id, tenant_slug: tenant_slug} =
      TestSupport.create_tenant_schema!("sweep-results")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant_slug)
    end)

    actor = %{
      id: Ash.UUID.generate(),
      email: "sweep-results@serviceradar.local",
      role: :admin,
      tenant_id: tenant_id
    }

    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, tenant_id: tenant_id, actor: actor, agent_id: agent_id}
  end

  test "ingest results updates devices and execution stats", %{
    tenant_id: tenant_id,
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    existing_ip = "10.1.0.#{rem(unique_id, 200) + 10}"
    new_ip = "10.1.1.#{rem(unique_id, 200) + 10}"

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
        tenant: tenant_id,
        authorize?: false
      )
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Group #{unique_id}"
        },
        actor: actor,
        tenant: tenant_id,
        authorize?: false
      )
      |> Ash.create()

    execution_id = Ash.UUID.generate()

    results = [
      %{
        "host_ip" => existing_ip,
        "hostname" => "existing-#{unique_id}",
        "icmp_available" => true,
        "icmp_response_time_ns" => 1_200_000,
        "tcp_ports_open" => [22, 443],
        "last_sweep_time" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      %{
        "host_ip" => new_ip,
        "hostname" => "new-#{unique_id}",
        "icmp_available" => false,
        "tcp_ports_open" => [],
        "error" => "timeout"
      }
    ]

    assert {:ok, stats} =
             SweepResultsIngestor.ingest_results(results, execution_id, tenant_id,
               actor: actor,
               sweep_group_id: group.id,
               agent_id: agent_id,
               config_version: "hash-#{unique_id}"
             )

    assert stats.hosts_total == 2
    assert stats.hosts_available == 1
    assert stats.hosts_failed == 1
    assert stats.devices_created == 1
    assert stats.devices_updated == 1

    assert {:ok, [existing_device]} =
             Device
             |> Ash.Query.filter(ip == ^existing_ip)
             |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

    assert existing_device.is_available
    assert "sweep" in existing_device.discovery_sources
    assert "netbox" in existing_device.discovery_sources

    assert {:ok, [new_device]} =
             Device
             |> Ash.Query.filter(ip == ^new_ip)
             |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

    refute new_device.is_available
    assert Enum.sort(new_device.discovery_sources) == ["sweep"]

    assert {:ok, host_results} =
             SweepHostResult
             |> Ash.Query.for_read(:by_execution, %{execution_id: execution_id})
             |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

    assert length(host_results) == 2

    assert Enum.any?(host_results, fn result ->
             result.ip == existing_ip and result.status == :available and
               result.open_ports == [22, 443]
           end)

    assert Enum.any?(host_results, fn result ->
             result.ip == new_ip and result.status in [:unavailable, :error]
           end)

    assert {:ok, [execution]} =
             SweepGroupExecution
             |> Ash.Query.filter(id == ^execution_id)
             |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

    assert execution.status == :completed
    assert execution.hosts_total == 2
    assert execution.hosts_available == 1
    assert execution.hosts_failed == 1
    assert execution.sweep_group_id == group.id
    assert execution.agent_id == agent_id
  end
end
