defmodule ServiceRadar.EventWriter.Processors.MtrTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Mtr

  defp message(map), do: %{data: Jason.encode!(map), metadata: %{}}

  defp envelope(extra \\ %{}) do
    Map.merge(
      %{
        "payload" => %{
          "results" => [%{"target" => "192.0.2.1", "trace_uuid" => Ecto.UUID.generate()}]
        },
        "status" => %{"agent_id" => "agent-01", "gateway_id" => "gw-01", "partition" => "default"}
      },
      extra
    )
  end

  test "parses the envelope into an ingest payload and atom-keyed status" do
    parsed = Mtr.parse_message(message(envelope()))

    assert [%{"target" => "192.0.2.1"}] = parsed.payload["results"]
    assert parsed.status == %{agent_id: "agent-01", gateway_id: "gw-01", partition: "default"}
    assert parsed.broadcast == nil
  end

  test "drops messages without a payload or that do not decode" do
    assert Mtr.parse_message(message(%{"status" => %{}})) == nil
    assert Mtr.parse_message(%{data: "not json"}) == nil
  end

  test "persists with skip_existing so a redelivered trace is not stored twice" do
    parsed = Mtr.parse_message(message(envelope()))

    ingest = fn payload, status, opts ->
      send(self(), {:ingest, payload, status, opts})
      :ok
    end

    assert :ok = Mtr.persist(parsed, ingest: ingest, broadcast: fn _ -> flunk("no broadcast") end)
    assert_received {:ingest, _payload, %{agent_id: "agent-01"}, [skip_existing: true]}
  end

  test "announces the trace only after it is stored" do
    announce = %{"command_id" => "cmd-1", "target" => "192.0.2.1", "agent_id" => "agent-01"}
    parsed = Mtr.parse_message(message(envelope(%{"broadcast" => announce})))

    stored = fn _payload, _status, _opts -> :ok end
    failed = fn _payload, _status, _opts -> {:error, :db_down} end
    broadcast = fn announced -> send(self(), {:broadcast, announced}) end

    assert :ok = Mtr.persist(parsed, ingest: stored, broadcast: broadcast)
    assert_received {:broadcast, %{command_id: "cmd-1", target: "192.0.2.1"}}

    assert {:error, :db_down} = Mtr.persist(parsed, ingest: failed, broadcast: broadcast)
    refute_received {:broadcast, _}
  end
end
