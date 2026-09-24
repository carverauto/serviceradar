defmodule ServiceRadar.EventWriter.Processors.MtrTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Mtr

  defp message(map), do: %{data: Jason.encode!(map), metadata: %{}}

  # The backend is chosen explicitly: other modules toggle the StarRocks switch
  # in application env, and these tests run concurrently with them.
  defp cnpg(opts), do: Keyword.put(opts, :starrocks_enabled, false)

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

    assert :ok =
             Mtr.persist(parsed,
               starrocks_enabled: false,
               ingest: ingest,
               broadcast: fn _ -> flunk("no broadcast") end
             )

    assert_received {:ingest, _payload, %{agent_id: "agent-01"}, [skip_existing: true]}
  end

  test "announces the trace only after it is stored" do
    announce = %{"command_id" => "cmd-1", "target" => "192.0.2.1", "agent_id" => "agent-01"}
    parsed = Mtr.parse_message(message(envelope(%{"broadcast" => announce})))

    stored = fn _payload, _status, _opts -> :ok end
    failed = fn _payload, _status, _opts -> {:error, :db_down} end
    broadcast = fn announced -> send(self(), {:broadcast, announced}) end

    assert :ok = Mtr.persist(parsed, cnpg(ingest: stored, broadcast: broadcast))
    assert_received {:broadcast, %{command_id: "cmd-1", target: "192.0.2.1"}}

    assert {:error, :db_down} = Mtr.persist(parsed, cnpg(ingest: failed, broadcast: broadcast))
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

      assert {:ok, 3} = Mtr.process_batch(messages, cnpg(ingest: ingest))
      assert ingested_targets() == ["192.0.2.1", "", "192.0.2.3"]
    end

    test "a batch with only permanent failures is handled" do
      messages = Enum.map(["192.0.2.1", "192.0.2.2"], &batch_message/1)

      ingest =
        recording_ingest(%{
          "192.0.2.1" => {:error, :missing_target_ip},
          "192.0.2.2" => {:error, :invalid_payload}
        })

      assert {:ok, 2} = Mtr.process_batch(messages, cnpg(ingest: ingest))
      assert ingested_targets() == ["192.0.2.1", "192.0.2.2"]
    end

    test "a transient failure is reported after every message was attempted" do
      messages = Enum.map(["192.0.2.1", "192.0.2.2", "192.0.2.3"], &batch_message/1)
      ingest = recording_ingest(%{"192.0.2.2" => {:error, :db_down}})

      assert {:error, :db_down} = Mtr.process_batch(messages, cnpg(ingest: ingest))
      assert ingested_targets() == ["192.0.2.1", "192.0.2.2", "192.0.2.3"]
    end
  end

  describe "with StarRocks enabled" do
    defp warehouse(opts) do
      test_pid = self()

      Keyword.merge(
        [
          starrocks_enabled: true,
          ingest: fn _payload, _status, _opts -> flunk("CNPG must not be written") end,
          load: fn dataset, rows ->
            send(test_pid, {:load, dataset, rows})
            {:ok, %{loaded: length(rows)}}
          end,
          project: fn results, status -> send(test_pid, {:project, results, status}) end,
          broadcast: fn announced -> send(test_pid, {:broadcast, announced}) end
        ],
        opts
      )
    end

    defp trace_message(extra \\ %{}) do
      trace_uuid = "9c8b7a69-5847-4362-9150-4f3e2d1c0b0a"

      result = %{
        "target" => "192.0.2.20",
        "trace_uuid" => trace_uuid,
        "timestamp" => 1_780_000_000,
        "trace" => %{
          "target_ip" => "192.0.2.20",
          "hops" => [
            %{"hop_number" => 1, "addr" => "198.51.100.1", "asn" => %{"asn" => 64_500}},
            %{"hop_number" => 2, "addr" => "192.0.2.20", "asn" => %{"asn" => 64_501}}
          ]
        }
      }

      message(envelope(Map.merge(%{"payload" => %{"results" => [result]}}, extra)))
    end

    test "traces and hops are loaded into the warehouse, and CNPG is not written" do
      announce = %{"command_id" => "cmd-2", "target" => "192.0.2.20", "agent_id" => "agent-01"}
      messages = [trace_message(%{"broadcast" => announce})]

      assert {:ok, 1} = Mtr.process_batch(messages, warehouse([]))

      assert_received {:load, :mtr_traces, [%{id: "9c8b7a69-5847-4362-9150-4f3e2d1c0b0a"}]}
      assert_received {:load, :mtr_hops, [%{hop_number: 1} = first, %{hop_number: 2}]}
      assert first.trace_id == "9c8b7a69-5847-4362-9150-4f3e2d1c0b0a"
      assert_received {:project, [%{"trace_uuid" => _}], %{agent_id: "agent-01"}}
      assert_received {:broadcast, %{command_id: "cmd-2"}}
    end

    test "a failed warehouse load fails the batch, and is not written to CNPG instead" do
      load = fn
        :mtr_traces, _rows -> {:ok, %{loaded: 1}}
        :mtr_hops, _rows -> {:error, {:warehouse_load, :mtr_hops, :connect_failed}}
      end

      assert {:error, {:warehouse_load, :mtr_hops, :connect_failed}} =
               Mtr.process_batch([trace_message()], warehouse(load: load))

      refute_received {:project, _, _}
      refute_received {:broadcast, _}
    end

    test "a redelivered trace loads the same keys again" do
      keys = fn ->
        assert {:ok, 1} = Mtr.process_batch([trace_message()], warehouse([]))
        assert_received {:load, :mtr_traces, traces}
        assert_received {:load, :mtr_hops, hops}
        Enum.map(traces ++ hops, &{&1.id, &1.time})
      end

      assert keys.() == keys.()
    end

    test "a trace that can never be stored is dropped, not retried" do
      messages = [message(envelope(%{"payload" => %{"results" => [%{"target" => ""}]}}))]

      assert {:ok, 1} = Mtr.process_batch(messages, warehouse([]))
      refute_received {:load, _, _}
    end
  end
end
