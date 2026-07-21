defmodule ServiceRadarAgentGateway.EdgeStreamProvisionerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.EdgeRoute
  alias ServiceRadarAgentGateway.EdgeStreamProvisioner, as: Prov

  defmodule FakeConn do
    @moduledoc false
    def request(subject, payload, _opts) do
      send(self(), {:requested, subject, payload})
      Process.get(:reply, {:ok, %{body: ~s({"config":{"name":"x"}})}})
    end
  end

  test "declares one data + one DLQ stream per lane, all disjoint" do
    configs = Prov.stream_configs()
    assert length(configs) == length(EdgeRoute.routable_lanes()) * 2

    names = Enum.map(configs, & &1.name)
    assert length(names) == length(Enum.uniq(names))

    for c <- configs do
      assert c.retention == "limits"
      assert c.discard == "new"
      assert c.storage == "file"
      assert c.max_msg_size >= 512 * 1024
      assert [subject] = c.subjects
      # single-token wildcard covering all 64 partitions
      assert String.contains?(subject, ".*.")
    end
  end

  test "data and DLQ subjects/streams are disjoint" do
    data = Prov.data_config(:sweep_bulk)
    dlq = Prov.dlq_config(:sweep_bulk)
    assert data.name != dlq.name
    assert data.subjects != dlq.subjects
    assert data.name == "EDGE_SWEEP_BULK_V1"
    assert dlq.name == "EDGE_DLQ_SWEEP_BULK_V1"
    assert data.subjects == ["sr.edge.v1.sweep.bulk.*.v1"]
    assert dlq.subjects == ["sr.edge.v1.dlq.sweep.bulk.*.v1"]
    # DLQ disables MaxAge so poison never expires silently.
    assert dlq.max_age == 0
  end

  test "ensure/3 posts to the JetStream create API and parses success" do
    Process.put(:reply, {:ok, %{body: ~s({"config":{"name":"EDGE_SWEEP_BULK_V1"}})}})

    assert {:ok, "EDGE_SWEEP_BULK_V1"} =
             Prov.ensure(FakeConn, Prov.data_config(:sweep_bulk))

    assert_received {:requested, "$JS.API.STREAM.CREATE.EDGE_SWEEP_BULK_V1", payload}
    assert Jason.decode!(payload)["subjects"] == ["sr.edge.v1.sweep.bulk.*.v1"]
  end

  test "an already-existing stream is treated as success" do
    body = ~s({"error":{"code":400,"err_code":10058,"description":"stream name already in use"}})
    assert {:ok, "EDGE_SWEEP_BULK_V1"} = Prov.parse_create(body, "EDGE_SWEEP_BULK_V1")
  end

  test "a real error is surfaced" do
    body = ~s({"error":{"code":500,"description":"insufficient storage"}})
    assert {:error, "N", %{"code" => 500}} = Prov.parse_create(body, "N")
  end

  test "ensure_all aggregates failures" do
    Process.put(:reply, {:error, :timeout})
    assert {:error, failures} = Prov.ensure_all(connection: FakeConn)
    assert length(failures) == length(EdgeRoute.routable_lanes()) * 2
    assert Enum.all?(failures, fn {_name, reason} -> reason == :timeout end)
  end

  test "ensure_all reports all names on success" do
    Process.put(:reply, {:ok, %{body: ~s({"config":{"name":"x"}})}})
    assert {:ok, names} = Prov.ensure_all(connection: FakeConn)
    assert length(names) == length(EdgeRoute.routable_lanes()) * 2
  end
end
