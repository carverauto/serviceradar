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

  describe "process_batch/2" do
    defp batch_message(target) do
      message(envelope(%{"payload" => %{"results" => [%{"target" => target}]}}))
    end

    defp recording_ingest(failures) do
      test_pid = self()

      fn %{"results" => [%{"target" => target}]}, _status, _opts ->
        send(test_pid, {:ingested, target})
        Map.get(failures, target, :ok)
      end
    end

    defp ingested_targets(acc \\ []) do
      receive do
        {:ingested, target} -> ingested_targets([target | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "a poison message does not stop later messages from being stored" do
      messages = Enum.map(["192.0.2.1", "", "192.0.2.3"], &batch_message/1)
      ingest = recording_ingest(%{"" => {:error, :missing_target_ip}})

      assert {:ok, 3} = Mtr.process_batch(messages, ingest: ingest)
      assert ingested_targets() == ["192.0.2.1", "", "192.0.2.3"]
    end

    test "a batch with only permanent failures is handled" do
      messages = Enum.map(["192.0.2.1", "192.0.2.2"], &batch_message/1)

      ingest =
        recording_ingest(%{
          "192.0.2.1" => {:error, :missing_target_ip},
          "192.0.2.2" => {:error, :invalid_payload}
        })

      assert {:ok, 2} = Mtr.process_batch(messages, ingest: ingest)
      assert ingested_targets() == ["192.0.2.1", "192.0.2.2"]
    end

    test "a transient failure is reported after every message was attempted" do
      messages = Enum.map(["192.0.2.1", "192.0.2.2", "192.0.2.3"], &batch_message/1)
      ingest = recording_ingest(%{"192.0.2.2" => {:error, :db_down}})

      assert {:error, :db_down} = Mtr.process_batch(messages, ingest: ingest)
      assert ingested_targets() == ["192.0.2.1", "192.0.2.2", "192.0.2.3"]
    end
  end
end
