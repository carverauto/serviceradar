defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.ProjectionNeighborDropTest do
  @moduledoc """
  Unit coverage (no database) for the removal of the non-`sr:` neighbor
  fallback in the AGE projection payload (fix-topology-evidence-pipeline-
  resilience, task 3.2): unresolved or non-canonical neighbors are dropped
  before graph projection — never fabricated into raw-IP/MAC pseudo-vertices —
  and the drop is accounted via the
  `[:serviceradar, :mapper_topology, :neighbor_dropped]` telemetry counter.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection

  defp fdb_link(overrides) do
    Map.merge(
      %{
        protocol: "snmp-l2",
        local_device_id: "sr:switch-a",
        local_device_ip: "192.0.2.10",
        local_if_name: "1/0/24",
        local_if_index: 24,
        neighbor_mgmt_addr: "192.0.2.77",
        neighbor_chassis_id: "aa:bb:cc:dd:ee:01",
        metadata: %{
          "source" => "snmp-arp-fdb",
          "confidence_tier" => "medium",
          "confidence_score" => 72,
          "confidence_reason" => "arp_fdb_port_mapping",
          "evidence_class" => "inferred-segment",
          "relation_family" => "ATTACHED_TO"
        },
        timestamp: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "projection_payload/1" do
    test "resolved sr: neighbor projects with both endpoints canonical" do
      payload = Projection.projection_payload(fdb_link(%{neighbor_device_id: "sr:endpoint-a"}))

      assert %{local_device_id: "sr:switch-a", neighbor_device_id: "sr:endpoint-a"} = payload
      assert Projection.drop_reason(fdb_link(%{neighbor_device_id: "sr:endpoint-a"})) == nil
    end

    test "unresolved neighbor is dropped instead of falling back to mgmt addr/chassis/name" do
      link =
        fdb_link(%{
          neighbor_device_id: nil,
          neighbor_system_name: "host-77"
        })

      assert Projection.projection_payload(link) == nil
      assert Projection.drop_reason(link) == :neighbor_unresolved
    end

    test "non-canonical neighbor id never becomes an AGE vertex" do
      for bogus <- ["192.0.2.77", "aa:bb:cc:dd:ee:01", "host-77", "default:192.0.2.77"] do
        link = fdb_link(%{neighbor_device_id: bogus})

        assert Projection.projection_payload(link) == nil,
               "expected non-sr neighbor #{inspect(bogus)} to be dropped"

        assert Projection.drop_reason(link) == :neighbor_not_canonical
      end
    end

    test "missing local id is classified separately" do
      link = fdb_link(%{local_device_id: nil, neighbor_device_id: "sr:endpoint-a"})

      assert Projection.projection_payload(link) == nil
      assert Projection.drop_reason(link) == :missing_local_id
    end
  end

  describe "projection_diagnostics/1" do
    test "counts neighbor drop reasons explicitly" do
      diagnostics =
        Projection.projection_diagnostics([
          fdb_link(%{neighbor_device_id: "sr:endpoint-a"}),
          fdb_link(%{neighbor_device_id: nil}),
          fdb_link(%{neighbor_device_id: "192.0.2.77"}),
          %{"protocol" => "LLDP"}
        ])

      assert diagnostics.total == 4
      assert diagnostics.rejected["neighbor_unresolved"] == 1
      assert diagnostics.rejected["neighbor_not_canonical"] == 1
      assert diagnostics.rejected["missing_local_id"] == 1
    end
  end

  describe "neighbor_dropped telemetry" do
    test "emits a counter with reason and protocol for neighbor drops" do
      handler_id = "neighbor-dropped-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :mapper_topology, :neighbor_dropped],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      link = fdb_link(%{neighbor_device_id: nil})

      assert :ok = Links.emit_neighbor_dropped(link, :neighbor_unresolved)

      assert_receive {:telemetry, [:serviceradar, :mapper_topology, :neighbor_dropped],
                      %{count: 1}, %{reason: :neighbor_unresolved, protocol: "snmp-l2"}}

      assert :ok = Links.emit_neighbor_dropped(link, :neighbor_not_canonical)

      assert_receive {:telemetry, [:serviceradar, :mapper_topology, :neighbor_dropped],
                      %{count: 1}, %{reason: :neighbor_not_canonical, protocol: "snmp-l2"}}
    end

    test "local-id drops are not neighbor drops" do
      handler_id = "neighbor-dropped-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :mapper_topology, :neighbor_dropped],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Links.emit_neighbor_dropped(fdb_link(%{}), :missing_local_id)

      refute_receive {:telemetry, [:serviceradar, :mapper_topology, :neighbor_dropped], _, _},
                     50
    end
  end
end
