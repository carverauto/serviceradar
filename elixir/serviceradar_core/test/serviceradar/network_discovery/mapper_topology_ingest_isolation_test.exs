defmodule ServiceRadar.NetworkDiscovery.MapperTopologyIngestIsolationTest do
  @moduledoc """
  Unit coverage (no database) for per-record failure isolation in mapper
  topology ingestion:

    * the Ash empty-string cast trap on `TopologyLink` logical-key columns —
      a provided `""` sentinel must survive casting instead of being re-cast
      to nil and rejected by the allow_nil? false validation, and
    * `handle_bulk_result/3` — partial bulk-create success must return the
      accepted records plus rejection pairs instead of aborting the pipeline,
      while keeping the TimescaleDB chunk-pkey special case and total-failure
      semantics intact.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ash.Error.Unknown.UnknownError
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyLink

  describe "TopologyLink empty-string sentinels" do
    test "explicit empty-string logical-key values survive casting" do
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      changeset =
        Ash.Changeset.for_create(TopologyLink, :create, %{
          timestamp: now,
          agent_id: "agent-test",
          partition: "default",
          protocol: "SNMP-L2",
          local_device_id: "sr:switch-under-test",
          local_if_index: 4,
          neighbor_device_id: "",
          neighbor_chassis_id: "aa:bb:cc:dd:ee:01",
          neighbor_port_id: "",
          neighbor_mgmt_addr: "192.0.2.77",
          metadata: %{"source" => "snmp-arp-fdb"},
          created_at: now
        })

      # Pre-fix, Ash's :string defaults (allow_empty?: false, trim?: true)
      # cast "" back to nil, defeating the ingestor's blank_to_empty coercion
      # and failing Required validation for FDB/UniFi-wireless/wireguard
      # records that legitimately lack these fields.
      assert Ash.Changeset.get_attribute(changeset, :neighbor_port_id) == ""
      assert Ash.Changeset.get_attribute(changeset, :neighbor_device_id) == ""
      assert Ash.Changeset.get_attribute(changeset, :protocol) == "SNMP-L2"
      assert changeset.valid?
    end

    test "all five logical-key string attributes accept empty strings" do
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      changeset =
        Ash.Changeset.for_create(TopologyLink, :create, %{
          timestamp: now,
          protocol: "",
          local_device_id: "",
          local_if_index: 0,
          neighbor_device_id: "",
          neighbor_chassis_id: "",
          neighbor_port_id: ""
        })

      for field <- [
            :protocol,
            :local_device_id,
            :neighbor_device_id,
            :neighbor_chassis_id,
            :neighbor_port_id
          ] do
        assert Ash.Changeset.get_attribute(changeset, field) == "",
               "expected #{field} to preserve the \"\" sentinel"
      end

      assert changeset.valid?
    end
  end

  describe "handle_bulk_result/3" do
    test "full success returns all prepared records as accepted" do
      records = [record("lldp", "sr:a"), record("snmp-l2", "sr:b")]
      result = %Ash.BulkResult{status: :success}

      assert {:ok, %{accepted: ^records, rejected: []}} =
               MapperResultsIngestor.handle_bulk_result(result, records, "topology")
    end

    test "partial success filters rejected records by bulk error index" do
      records = [record("lldp", "sr:a"), record("snmp-l2", "sr:b"), record("lldp", "sr:c")]
      error = required_error(:neighbor_port_id, 1)
      result = %Ash.BulkResult{status: :partial_success, errors: [error], error_count: 1}

      log =
        capture_log(fn ->
          assert {:ok, %{accepted: accepted, rejected: rejected}} =
                   MapperResultsIngestor.handle_bulk_result(result, records, "topology")

          assert accepted == [Enum.at(records, 0), Enum.at(records, 2)]
          assert [{rejected_record, %Ash.Error.Invalid{}}] = rejected
          assert rejected_record == Enum.at(records, 1)
        end)

      assert log =~ "[error]"
      assert log =~ "rejected 1 of 3 record(s)"
    end

    test "partial success with an unattributable error keeps the batch and reports the error" do
      records = [record("lldp", "sr:a"), record("lldp", "sr:b")]
      error = Ash.Error.to_error_class([UnknownError.exception(error: "boom")])
      result = %Ash.BulkResult{status: :partial_success, errors: [error], error_count: 1}

      capture_log(fn ->
        assert {:ok, %{accepted: ^records, rejected: [{nil, _error}]}} =
                 MapperResultsIngestor.handle_bulk_result(result, records, "topology")
      end)
    end

    test "partial success keeps the TimescaleDB chunk-pkey special case" do
      records = [record("lldp", "sr:a")]

      error =
        UnknownError.exception(
          error: ~s|unique_constraint: constraint "1_2_mapper_topology_links_pkey" violated|
        )

      result = %Ash.BulkResult{status: :partial_success, errors: [error], error_count: 1}

      assert {:ok, %{accepted: ^records, rejected: []}} =
               MapperResultsIngestor.handle_bulk_result(result, records, "topology")
    end

    test "total failure still returns an error" do
      records = [record("lldp", "sr:a")]
      error = required_error(:timestamp, 0)
      result = %Ash.BulkResult{status: :error, errors: [error], error_count: 1}

      capture_log(fn ->
        assert {:error, [_error]} =
                 MapperResultsIngestor.handle_bulk_result(result, records, "topology")
      end)
    end

    test "total failure of only TimescaleDB chunk-pkey duplicates is treated as accepted" do
      records = [record("lldp", "sr:a")]

      error =
        UnknownError.exception(
          error: ~s|unique_constraint: constraint "3_7_discovered_interfaces_pkey" violated|
        )

      result = %Ash.BulkResult{status: :error, errors: [error], error_count: 1}

      assert {:ok, %{accepted: ^records, rejected: []}} =
               MapperResultsIngestor.handle_bulk_result(result, records, "interfaces")
    end
  end

  describe "emit_topology_ingest_rejections/1" do
    test "emits one event per (reason, protocol, agent) group with counts" do
      handler_id = "ingest-rejected-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :mapper_topology, :ingest_rejected],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      error = required_error(:neighbor_port_id, 0)

      rejected = [
        {record("SNMP-L2", "sr:a"), error},
        {record("SNMP-L2", "sr:b"), error},
        {record("UniFi-API", "sr:c"), error}
      ]

      assert :ok = MapperResultsIngestor.emit_topology_ingest_rejections(rejected)

      assert_receive {:telemetry, [:serviceradar, :mapper_topology, :ingest_rejected],
                      %{count: 2},
                      %{
                        reason: "required:neighbor_port_id",
                        protocol: "SNMP-L2",
                        agent_id: "agent-test"
                      }}

      assert_receive {:telemetry, [:serviceradar, :mapper_topology, :ingest_rejected],
                      %{count: 1},
                      %{
                        reason: "required:neighbor_port_id",
                        protocol: "UniFi-API",
                        agent_id: "agent-test"
                      }}
    end

    test "unattributable rejections fall back to unknown protocol and agent" do
      handler_id = "ingest-rejected-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :mapper_topology, :ingest_rejected],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      error = Ash.Error.to_error_class([UnknownError.exception(error: "boom")])

      assert :ok = MapperResultsIngestor.emit_topology_ingest_rejections([{nil, error}])

      assert_receive {:telemetry, [:serviceradar, :mapper_topology, :ingest_rejected],
                      %{count: 1}, %{protocol: "unknown", agent_id: "unknown"}}
    end
  end

  defp record(protocol, local_device_id) do
    %{
      timestamp: DateTime.truncate(DateTime.utc_now(), :microsecond),
      agent_id: "agent-test",
      partition: "default",
      protocol: protocol,
      local_device_id: local_device_id,
      local_if_index: 1,
      neighbor_device_id: "",
      neighbor_chassis_id: "",
      neighbor_port_id: "",
      metadata: %{}
    }
  end

  defp required_error(field, index) do
    [Ash.Error.Changes.Required.exception(field: field, type: :attribute, resource: TopologyLink)]
    |> Ash.Error.to_error_class()
    |> Ash.Error.set_path([index])
  end
end
