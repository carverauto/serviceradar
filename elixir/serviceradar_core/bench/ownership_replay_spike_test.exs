defmodule ServiceRadar.Bench.OwnershipReplaySpikeTest do
  @moduledoc """
  Phase 0 replay experiment, using a disposable file-backed JetStream on RBE.

  The corpus spans two hours of event time, loaded faster than real time. A broker
  restart proves the messages survive on disk; this is not a cold filesystem-cache
  measurement. A new pull consumer rebuilds empty packed ETS tables. JSON maps are
  an experiment encoding, not a new production wire contract. Every event carries
  its owner context; neither owners nor keys are preloaded into the reader.

  This measures transport, JSON decode, owner interning and interval application.
  It does not implement the production shard's expiry wheel, snapshot membership,
  address presence, placement, enrichment or notifications. Memory is a floor and
  replay time is preliminary, even when the separate capacity verdict is within
  target. The small default corpus tests the experiment, not fleet capacity.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 1_800_000
  @stream "synthetic_ownership"
  @subject "synthetic.ownership.0"
  @consumer "synthetic_rebuild"
  @rows_per_message 500
  @pull_messages 8
  @horizon 900

  @tag :tmp_dir
  test "rebuild packed histories from persisted two-hour ownership events", %{tmp_dir: dir} do
    count = "OWNERSHIP_REPLAY_KEYS" |> System.get_env("2500") |> String.to_integer()
    profile = System.fetch_env!("OWNERSHIP_REPLAY_PROFILE")
    copy = System.get_env("OWNERSHIP_REPLAY_COPY", "none")
    assert count >= 100 and count <= 2_500_000 and rem(count, 100) == 0
    assert profile in ["single", "mixed", "reuse"]
    assert copy in ["none", "history", "key"]
    {:ok, _} = Application.ensure_all_started(:gnat)

    # ex_unit_test stages declared external data under TEST_TMPDIR/external.
    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    try do
      {load_us, {messages, events, bytes}} =
        :timer.tc(fn ->
          with_broker(executable, dir, fn conn ->
            create_stream(conn)
            seed(conn, count, profile)
          end)
        end)

      expected_events =
        div(count, 100) * Map.fetch!(%{"single" => 500, "mixed" => 606, "reuse" => 930}, profile) +
          6

      assert events == expected_events

      IO.puts(
        "ownership_replay_seed profile=#{profile} keys=#{count} events=#{events} " <>
          "messages=#{messages} payload_bytes=#{bytes} load_s=#{seconds(load_us)} synthetic=true"
      )

      with_broker(executable, dir, fn conn ->
        state = api(conn, "$JS.API.STREAM.INFO.#{@stream}")["state"]
        assert state["messages"] == messages
        assert state["first_seq"] == 1
        assert state["last_seq"] == messages
        measure(conn, count, profile, messages, events, copy)
      end)
    after
      File.rm_rf!(dir)
    end
  end

  defp create_stream(conn) do
    result =
      api(conn, "$JS.API.STREAM.CREATE.#{@stream}", %{
        name: @stream,
        subjects: [@subject],
        storage: "file",
        retention: "limits",
        discard: "new",
        max_age: 7_200_000_000_000,
        max_bytes: 24 * 1024 * 1024 * 1024,
        num_replicas: 1
      })

    assert result["config"]["storage"] == "file"
    assert result["config"]["discard"] == "new"
  end

  defp seed(conn, count, profile) do
    # Four fleet-wide epochs, then each key's final renewal or close/reuse history.
    # Per-key order is chronological; independent keys need no global time order.
    epochs =
      Stream.flat_map([-7200, -5400, -3600, -1800], fn seen ->
        Stream.map(1..count, &event(&1, 0, -7200, seen, false, count))
      end)

    tail = Stream.flat_map(1..count, &tail_events(&1, depth(profile, &1), count))

    [epochs, tail, controls(count)]
    |> Stream.concat()
    |> Stream.chunk_every(@rows_per_message)
    |> Enum.reduce({0, 0, 0}, fn rows, {messages, events, bytes} ->
      payload = Jason.encode!(%{batch: messages + 1, events: rows})
      assert byte_size(payload) < 1_048_576
      {:ok, %{body: body}} = Gnat.request(conn, @subject, payload, receive_timeout: 30_000)
      ack = Jason.decode!(body)
      assert ack["stream"] == @stream
      assert ack["seq"] == messages + 1
      refute ack["duplicate"]
      {messages + 1, events + length(rows), bytes + byte_size(payload)}
    end)
  end

  defp tail_events(id, 1, count), do: [event(id, 0, -7200, 0, false, count)]

  defp tail_events(id, depth, count) do
    first_close = -25 * (depth - 1)

    [event(id, 0, -7200, first_close, true, count)] ++
      Enum.flat_map(1..(depth - 1), fn generation ->
        first = first_close + (generation - 1) * 25
        opened = event(id, generation, first, first, false, count)

        if generation == depth - 1 do
          [opened]
        else
          [opened, event(id, generation, first, first + 25, true, count)]
        end
      end)
  end

  defp controls(count) do
    closed = event(count + 1, 0, -120, -60, true, count)

    [
      event(count + 1, 0, -120, -120, false, count),
      closed,
      closed,
      # An old renewal arriving after CLOSE must not reopen the interval.
      event(count + 1, 0, -120, -90, false, count),
      # Expired inside the history horizon, then expired outside it.
      event(count + 2, 0, -4000, -3601, false, count),
      event(count + 3, 0, -5000, -4501, false, count)
    ]
  end

  defp event(id, generation, first, seen, closed, count) do
    owner_id = rem(div(id - 1, 128) + generation, div(count + 127, 128)) + 1

    %{
      key: Base.encode64(key(id)),
      lease: id * 32 + generation,
      first: first,
      seen: seen,
      ttl: 3600,
      closed: closed,
      owner: %{
        agent_id: "synthetic-agent-#{div(owner_id, 16)}",
        pid: owner_id,
        uid: 1000,
        comm: "synthetic-service",
        cmdline: "synthetic-service " <> String.duplicate("x", 238),
        container_id: "synthetic-container-#{owner_id}",
        workload_identity: "synthetic-workload-#{owner_id}",
        executable_ownership: %{
          resolution_state: "RESOLVED",
          package_name: "synthetic-package",
          installed_version: "1.0.0",
          executable_path: "/usr/bin/synthetic-service"
        }
      }
    }
  end

  defp measure(conn, count, profile, messages, events, copy) do
    :erlang.garbage_collect()
    before = :erlang.memory()
    started = System.monotonic_time(:microsecond)
    keys = :ets.new(:keys, [:set, :private])
    owners = :ets.new(:owners, [:set, :private])
    owner_ids = :ets.new(:owner_ids, [:set, :private])
    store = {keys, owners, owner_ids}
    {:ok, sid} = Gnat.sub(conn, self(), "_INBOX.synthetic_replay")

    try do
      api(conn, "$JS.API.CONSUMER.DURABLE.CREATE.#{@stream}.#{@consumer}", %{
        stream_name: @stream,
        config: %{
          durable_name: @consumer,
          deliver_policy: "all",
          replay_policy: "instant",
          ack_policy: "explicit",
          ack_wait: 60_000_000_000,
          max_ack_pending: @pull_messages
        }
      })

      phases = %{pull: 0, wait: 0, decode: 0, apply: 0, ack: 0}

      {stats, phases} =
        replay({conn, sid, copy}, store, 1, messages, {{0, 0, -7200}, phases})

      assert stats == {events, -7200, 0}
      settled!(conn, messages, 100)
      replay_us = System.monotonic_time(:microsecond) - started

      :erlang.garbage_collect()
      before_verify = :erlang.memory()
      verify_store(store, count, profile)

      :erlang.garbage_collect()
      after_load = :erlang.memory()

      ets_bytes =
        Enum.sum(for table <- Tuple.to_list(store), do: :ets.info(table, :memory)) *
          :erlang.system_info(:wordsize)

      payload = binary_payload(keys) + binary_payload(owners)
      binary_growth = max(after_load[:binary] - before[:binary], payload)
      memory_floor = (ets_bytes + binary_growth) / count

      report_costs(store, phases, replay_us, before, before_verify, after_load)

      IO.puts(
        "ownership_replay_result protocol=2 copy=#{copy} profile=#{profile} keys=#{count} events=#{events} " <>
          "replay_s=#{seconds(replay_us)} replay_time_target=#{verdict(replay_us <= 120_000_000)} " <>
          "events_per_s=#{round(events * 1_000_000 / max(replay_us, 1))} " <>
          "bytes_per_key_floor=#{Float.round(memory_floor, 1)} " <>
          "memory_floor_gate=#{verdict(memory_floor <= 200)} " <>
          "vm_growth=#{max(after_load[:total] - before[:total], 0)} " <>
          "owners=#{:ets.info(owners, :size)} otp=#{System.otp_release()} " <>
          "schedulers=#{:erlang.system_info(:schedulers_online)} " <>
          "full_shard_gate=unmeasured"
      )
    after
      Gnat.unsub(conn, sid)
      Enum.each(Tuple.to_list(store), &:ets.delete/1)
    end
  end

  defp replay(_conn, _store, next, total, stats) when next > total, do: stats

  defp replay({conn, sid, copy} = reader, store, next, total, {stats, phases}) do
    batch = min(@pull_messages, total - next + 1)
    started = System.monotonic_time(:microsecond)

    :ok =
      Gnat.Jetstream.API.Consumer.request_next_message(
        conn,
        @stream,
        @consumer,
        "_INBOX.synthetic_replay",
        nil,
        batch: batch,
        expires: 10_000_000_000
      )

    phases = %{phases | pull: phases.pull + System.monotonic_time(:microsecond) - started}

    result =
      Enum.reduce(next..(next + batch - 1), {stats, phases}, fn sequence, {stats, phases} ->
        started = System.monotonic_time(:microsecond)
        assert_receive {:msg, %{sid: ^sid} = message}, 15_000
        refute Map.has_key?(message, :status)
        received = System.monotonic_time(:microsecond)
        %{"batch" => ^sequence, "events" => rows} = Jason.decode!(message.body)
        decoded = System.monotonic_time(:microsecond)

        stats =
          Enum.reduce(rows, stats, fn row, {events, first, last} ->
            apply_event(store, row, copy)
            {events + 1, min(first, row["seen"]), max(last, row["seen"])}
          end)

        applied = System.monotonic_time(:microsecond)
        :ok = Gnat.pub(conn, message.reply_to, "+ACK")
        acknowledged = System.monotonic_time(:microsecond)

        {stats,
         %{
           phases
           | wait: phases.wait + received - started,
             decode: phases.decode + decoded - received,
             apply: phases.apply + applied - decoded,
             ack: phases.ack + acknowledged - applied
         }}
      end)

    replay(reader, store, next + batch, total, result)
  end

  defp apply_event({keys, owners, owner_ids}, row, copy) do
    finish = if row["closed"], do: row["seen"], else: row["seen"] + row["ttl"]

    if finish >= -@horizon do
      owner = :erlang.term_to_binary(row["owner"])

      owner_id =
        case :ets.lookup(owner_ids, owner) do
          [{^owner, id}] ->
            id

          [] ->
            id = :ets.info(owners, :size) + 1
            :ets.insert(owners, {id, owner})
            :ets.insert(owner_ids, {owner, id})
            id
        end

      key = maybe_copy(Base.decode64!(row["key"]), copy == "key")

      history =
        case :ets.lookup(keys, key) do
          [{^key, value}] -> value
          [] -> <<>>
        end

      interval = {row["first"], finish, owner_id, if(row["closed"], do: 1, else: 0), row["lease"]}
      :ets.insert(keys, {key, maybe_copy(upsert(history, interval), copy == "history")})
    end
  end

  defp maybe_copy(binary, true), do: :binary.copy(binary)
  defp maybe_copy(binary, false), do: binary

  defp report_costs(
         {keys, owners, owner_ids},
         phases,
         replay_us,
         before,
         before_verify,
         after_load
       ) do
    measured = phases |> Map.values() |> Enum.sum()
    assert measured <= replay_us

    IO.puts(
      "ownership_replay_phases_us pull=#{phases.pull} wait=#{phases.wait} " <>
        "decode=#{phases.decode} apply=#{phases.apply} ack=#{phases.ack} " <>
        "other=#{replay_us - measured} total=#{replay_us}"
    )

    wordsize = :erlang.system_info(:wordsize)

    IO.puts(
      "ownership_replay_memory keys_ets=#{:ets.info(keys, :memory) * wordsize} " <>
        "owners_ets=#{:ets.info(owners, :memory) * wordsize} " <>
        "owner_ids_ets=#{:ets.info(owner_ids, :memory) * wordsize} " <>
        "binary_growth_before_verify=#{before_verify[:binary] - before[:binary]} " <>
        "binary_growth_after_verify=#{after_load[:binary] - before[:binary]} " <>
        "known_offheap_payload=#{binary_payload(keys) + binary_payload(owners)}"
    )

    # Referenced-byte sums diagnose backing storage; they are not allocation totals
    # (a shared backing binary can be counted more than once). Outside replay time.
    {key_bytes, key_refs, history_bytes, history_refs} =
      :ets.foldl(
        fn {key, history}, {kb, kr, hb, hr} ->
          {kb + byte_size(key), kr + :binary.referenced_byte_size(key), hb + byte_size(history),
           hr + :binary.referenced_byte_size(history)}
        end,
        {0, 0, 0, 0},
        keys
      )

    IO.puts(
      "ownership_replay_binaries key_bytes=#{key_bytes} key_referenced_bytes=#{key_refs} " <>
        "history_bytes=#{history_bytes} history_referenced_bytes=#{history_refs}"
    )
  end

  defp upsert(<<>>, {first, finish, owner, closed, lease}) do
    <<first::signed-64, finish::signed-64, owner::32, closed::32, lease::64>>
  end

  defp upsert(
         <<first::signed-64, finish::signed-64, owner::32, closed::32, lease::64, rest::binary>>,
         {new_first, new_finish, new_owner, new_closed, new_lease} = interval
       ) do
    if lease == new_lease do
      assert first == new_first and owner == new_owner

      finish =
        cond do
          closed == 1 -> finish
          new_closed == 1 -> new_finish
          true -> max(finish, new_finish)
        end

      <<first::signed-64, finish::signed-64, owner::32, max(closed, new_closed)::32, lease::64,
        rest::binary>>
    else
      <<first::signed-64, finish::signed-64, owner::32, closed::32, lease::64,
        upsert(rest, interval)::binary>>
    end
  end

  defp verify_store({keys, owners, _owner_ids}, count, profile) do
    assert :ets.info(keys, :size) == count + 2

    Enum.each(1..count, fn id ->
      [{_, history}] = :ets.lookup(keys, key(id))
      assert byte_size(history) == depth(profile, id) * 32
      owner_id = lookup(history, 0)
      [{^owner_id, owner}] = :ets.lookup(owners, owner_id)
      expected_pid = rem(div(id - 1, 128) + depth(profile, id) - 1, div(count + 127, 128)) + 1
      assert :erlang.binary_to_term(owner)["pid"] == expected_pid
      assert lookup(history, 3600) == :not_found

      if depth(profile, id) > 1 do
        prior_id = lookup(history, -26)
        [{^prior_id, prior}] = :ets.lookup(owners, prior_id)
        expected_prior = rem(div(id - 1, 128) + depth(profile, id) - 2, div(count + 127, 128)) + 1
        assert :erlang.binary_to_term(prior)["pid"] == expected_prior
      end
    end)

    [{_, closed}] = :ets.lookup(keys, key(count + 1))
    assert lookup(closed, -61) != :not_found
    assert lookup(closed, -60) == :not_found
    assert lookup(closed, 0) == :not_found
    assert byte_size(closed) == 32
    [{_, expired}] = :ets.lookup(keys, key(count + 2))
    assert lookup(expired, -2) != :not_found
    assert lookup(expired, 0) == :not_found
    assert :ets.lookup(keys, key(count + 3)) == []
  end

  defp lookup(<<>>, _time), do: :not_found

  defp lookup(
         <<first::signed-64, finish::signed-64, owner::32, _flags::32, _lease::64, rest::binary>>,
         time
       ) do
    if first <= time and time < finish, do: owner, else: lookup(rest, time)
  end

  defp key(id) do
    local = <<0x20010DB8::32, id::96>>
    remote = <<0x20010DB8::32, 1::32, id::64>>
    port = 10_000 + rem(id, 50_000)

    case rem(id, 20) do
      n when n < 16 -> <<0, 1::32, 6, local::binary, port::16>>
      n when n < 19 -> <<1, 1::32, 6, local::binary, port::16, remote::binary, 443::16>>
      _ -> <<2, 1::32, 17, local::binary, remote::binary, 443::16>>
    end
  end

  defp depth("single", _id), do: 1
  defp depth("mixed", id) when rem(id, 100) < 90, do: 1
  defp depth("mixed", id) when rem(id, 100) < 99, do: 4
  defp depth("mixed", _id), do: 32
  defp depth("reuse", id) when rem(id, 100) < 70, do: 1
  defp depth("reuse", id) when rem(id, 100) < 95, do: 4
  defp depth("reuse", _id), do: 32

  defp binary_payload(table) do
    :ets.foldl(
      fn {_key, value}, bytes ->
        if byte_size(value) > 64, do: bytes + byte_size(value), else: bytes
      end,
      0,
      table
    )
  end

  defp settled!(conn, last, attempts) do
    state = api(conn, "$JS.API.CONSUMER.INFO.#{@stream}.#{@consumer}")

    if state["num_pending"] == 0 and state["num_ack_pending"] == 0 and
         state["ack_floor"]["stream_seq"] == last do
      :ok
    else
      assert attempts > 0, "consumer never reached the persisted end of the corpus"
      Process.sleep(10)
      settled!(conn, last, attempts - 1)
    end
  end

  defp api(conn, subject, payload \\ %{}) do
    {:ok, %{body: body}} =
      Gnat.request(conn, subject, Jason.encode!(payload), receive_timeout: 30_000)

    result = Jason.decode!(body)
    refute Map.has_key?(result, "error"), inspect(result)
    result
  end

  defp with_broker(executable, dir, fun) do
    File.mkdir_p!(dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-js",
          "-a",
          "127.0.0.1",
          "-p",
          "-1",
          "-sd",
          Path.join(dir, "store"),
          "--ports_file_dir",
          dir,
          "-l",
          Path.join(dir, "broker.log")
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      uri = broker_uri(dir, pid, 300)
      {:ok, conn} = Gnat.start_link(%{host: "127.0.0.1", port: URI.parse(uri).port})

      try do
        fun.(conn)
      after
        Gnat.stop(conn)
      end
    after
      {_output, 0} = System.cmd(executable, ["--signal", "quit=#{pid}"], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, status}}, 30_000
      assert status == 0
    end
  end

  defp broker_uri(dir, pid, attempts) do
    path = Path.join(dir, "nats-server_#{pid}.ports")

    case File.read(path) do
      {:ok, body} ->
        %{"nats" => [uri]} = Jason.decode!(body)
        uri

      {:error, :enoent} ->
        assert attempts > 0, "disposable NATS broker did not start"
        Process.sleep(100)
        broker_uri(dir, pid, attempts - 1)
    end
  end

  defp seconds(us), do: Float.round(us / 1_000_000, 2)
  defp verdict(true), do: "within"
  defp verdict(false), do: "exceeded"
end
