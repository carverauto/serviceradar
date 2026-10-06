defmodule ServiceRadar.DgraphTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.Dgraph.Call
  alias ServiceRadar.Dgraph.Native

  @dgraph_url System.get_env("DGRAPH_URL")

  setup do
    previous_url = Application.get_env(:serviceradar_core, :dgraph_url)
    previous_host = Application.get_env(:serviceradar_core, :dgraph_host)
    previous_port = Application.get_env(:serviceradar_core, :dgraph_port)
    previous_tls = Application.get_env(:serviceradar_core, :dgraph_tls_mode)

    on_exit(fn ->
      put_app(:dgraph_url, previous_url)
      put_app(:dgraph_host, previous_host)
      put_app(:dgraph_port, previous_port)
      put_app(:dgraph_tls_mode, previous_tls)
    end)

    :ok
  end

  test "url prefers DGRAPH_URL over application env" do
    Application.put_env(:serviceradar_core, :dgraph_url, "dgraph://app.example:9080")

    env_url = System.get_env("DGRAPH_URL")

    System.put_env(
      "DGRAPH_URL",
      "dgraph://groot:password@alpha.example:9080?sslmode=disable"
    )

    try do
      assert {:ok, "dgraph://groot:password@alpha.example:9080?sslmode=disable"} = Dgraph.url()
    after
      restore_env("DGRAPH_URL", env_url)
    end
  end

  test "url assembles host/port/tls when DGRAPH_URL is unset" do
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")
    env_port = System.get_env("DGRAPH_PORT")
    env_tls = System.get_env("DGRAPH_TLS_MODE")

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    System.delete_env("DGRAPH_PORT")
    System.delete_env("DGRAPH_TLS_MODE")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.put_env(:serviceradar_core, :dgraph_host, "alpha.example")
    Application.put_env(:serviceradar_core, :dgraph_port, 9080)
    Application.put_env(:serviceradar_core, :dgraph_tls_mode, "require")

    try do
      assert {:ok, "dgraph://alpha.example:9080?sslmode=require"} = Dgraph.url()
    after
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
      restore_env("DGRAPH_PORT", env_port)
      restore_env("DGRAPH_TLS_MODE", env_tls)
    end
  end

  test "url errors when nothing is configured" do
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    try do
      assert {:error, reason} = Dgraph.url()
      assert reason =~ "not configured"
    after
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
    end
  end

  test "query refuses mutations without contacting dgraph" do
    env_url = System.get_env("DGRAPH_URL")
    System.delete_env("DGRAPH_URL")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    try do
      assert {:error, reason} = Dgraph.query("mutation { set { _:x <dgraph.type> \"Device\" } }")
      assert reason =~ "refuses mutations"

      assert {:error, _} = Dgraph.query("set { _:x <device.id> \"sr:host01.example.com\" }")
      assert {:error, _} = Dgraph.query("delete { uid(v) * * . }")
      assert {:error, _} = Dgraph.query("upsert { query { q(func: uid(0x1)) { uid } } }")
      assert {:error, "dql query is empty"} = Dgraph.query("   ")
    after
      restore_env("DGRAPH_URL", env_url)
    end
  end

  test "mutation?/1 allows read-only DQL" do
    refute Dgraph.mutation?("{ q(func: eq(device.id, \"sr:host01.example.com\")) { uid } }")
    refute Dgraph.mutation?("{ q(func: eq(device.id, \"mutation-lab\")) { uid } }")
    assert Dgraph.mutation?("MUTATION{\n  set { _:x <dgraph.type> \"Device\" }\n}")
  end

  test "native reads reject mutations and unconfigured graph requests without connecting" do
    assert {:error, mutation_reason} =
             Native.query_dql(
               "dgraph://unused:9080",
               "mutation { set { _:x <dgraph.type> \"Device\" } }",
               1_000
             )

    assert mutation_reason =~ "refuses mutations"
    assert {:error, graph_reason} = Native.query_canonical_graph("", 1_000)
    assert graph_reason =~ "not configured"
    refute_received {:dgraph_nif_reply, _, _, _}
  end

  test "hosted replacement reaches its NIF binding for invalid hosted input" do
    env_url = System.get_env("DGRAPH_URL")
    System.put_env("DGRAPH_URL", "dgraph://unused.example.test:9080?sslmode=disable")

    edge = %{
      source: "synthetic-guest",
      target: "synthetic-host",
      kind: :hosted_on,
      protocol: "virtualization_inventory",
      evidence_class: "hosted-virtual",
      ingestor: "hypervisor_enrichment_v1",
      last_seen: "2030-02-03T04:05:06Z"
    }

    try do
      for invalid <- [
            %{kind: :attached_to},
            %{ingestor: "synthetic-other-projection"},
            %{target: edge.source},
            %{last_seen: ""}
          ] do
        assert {:error,
                "upsert @if skipped: hosted replacement empty for " <>
                  "hosted replacement requires virtualization projection, distinct endpoints, and an observation timestamp"} =
                 Dgraph.replace_hosted_edge(Map.merge(edge, invalid))
      end
    after
      restore_env("DGRAPH_URL", env_url)
    end
  end

  @tag :dgraph
  @tag skip: @dgraph_url in [nil, ""]
  test "upserts a synthetic device against the configured cluster" do
    id = "sr:host01.example.com"

    assert :ok =
             Dgraph.upsert_device(%{
               id: id,
               hostname: "host01.example.com",
               ip: "192.0.2.10"
             })

    assert {:ok, payload} =
             Dgraph.query("{ q(func: eq(device.id, \"#{id}\")) { device.id device.hostname } }")

    nodes = Map.get(payload, "q", [])
    assert Enum.any?(nodes, fn node -> node["device.id"] == id end)
  end

  describe "a stalled Dgraph" do
    setup do
      # Accepts TCP connections from its backlog and never answers: the shape of
      # a black-holed or wedged Dgraph alpha.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, backlog: 1024])
      {:ok, port} = :inet.port(listener)
      env_url = System.get_env("DGRAPH_URL")
      previous_config = Application.get_env(:serviceradar_core, Dgraph)
      System.put_env("DGRAPH_URL", "dgraph://127.0.0.1:#{port}?sslmode=disable")

      on_exit(fn ->
        restore_env("DGRAPH_URL", env_url)
        put_app(Dgraph, previous_config)
        :gen_tcp.close(listener)
      end)

      :ok
    end

    test "stalled bulk calls cannot take the per-item call slots" do
      Application.put_env(:serviceradar_core, Dgraph,
        item_deadline_ms: 800,
        reply_margin_ms: 1_000
      )

      {:ok, url} = Dgraph.url()

      # More stalled whole-graph reads than there are in-flight slots.
      bulk =
        for _ <- 1..10 do
          assert {:ok, _ref, handle} = Native.query_canonical_graph(url, 5_000)
          handle
        end

      on_exit(fn -> Enum.each(bulk, &Native.cancel/1) end)

      assert {:error, reason} = Dgraph.query("{ q(func: uid(0x1)) { uid } }")
      # The item call got a slot and failed on its own stalled connect, rather
      # than waiting out its deadline behind the bulk calls.
      refute reason =~ "waiting for an in-flight slot", reason
      assert reason =~ "timed out"
    end

    test "a call whose caller dies releases its slot" do
      Application.put_env(:serviceradar_core, Dgraph,
        item_deadline_ms: 1_000,
        reply_margin_ms: 1_000
      )

      {:ok, url} = Dgraph.url()
      parent = self()

      callers =
        for _ <- 1..10 do
          spawn(fn ->
            {:ok, _ref, _handle} = Native.query_dql(url, "{ q(func: uid(0x1)) { uid } }", 10_000)
            send(parent, {:submitted, self()})

            receive do
              :never -> :ok
            end
          end)
        end

      for caller <- callers, do: assert_receive({:submitted, ^caller}, 1_000)

      for caller <- callers do
        ref = Process.monitor(caller)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
      end

      # Without cancellation the dead callers' calls would hold every slot for
      # their full 10s deadline.
      assert {:error, reason} = Dgraph.query("{ q(func: uid(0x1)) { uid } }")
      refute reason =~ "waiting for an in-flight slot", reason
      assert reason =~ "timed out"
    end

    test "holds no dirty-IO scheduler, however many calls are stalled" do
      Application.put_env(:serviceradar_core, Dgraph,
        item_deadline_ms: 3_000,
        reply_margin_ms: 1_000
      )

      stalled = :erlang.system_info(:dirty_io_schedulers) + 4

      calls =
        for _ <- 1..stalled do
          Task.async(fn -> Dgraph.query("{ q(func: uid(0x1)) { uid } }") end)
        end

      # File I/O runs on the dirty-IO schedulers. A Dgraph call that blocks one
      # of them leaves it unavailable here until the call returns. Probe for a
      # while rather than once, so the probe also runs after every call has
      # reached the native layer.
      path =
        Path.join(
          System.tmp_dir!(),
          "dgraph-scheduler-probe-#{System.unique_integer([:positive])}"
        )

      probe_until = System.monotonic_time(:millisecond) + 1_500
      probes = probe_file_io(path, probe_until, 0)
      assert probes > 0

      File.rm(path)

      for call <- calls do
        assert {:error, reason} = Task.await(call, 10_000)
        assert reason =~ "timed out"
      end
    end

    test "a call abandoned at the caller's deadline is cancelled and never replies" do
      {:ok, url} = Dgraph.url()
      assert {:ok, ref, handle} = Native.query_dql(url, "{ q(func: uid(0x1)) { uid } }", 800)

      assert {{:error, reason}, :timeout} =
               Call.await(:query_dql, ref, handle, &Native.cancel/1, 50)

      assert reason =~ "cancelled"
      # Well past the native deadline: a late reply would have arrived by now.
      refute_receive {:dgraph_nif_reply, ^ref, _, _}, 2_000
    end

    test "reports queue wait and duration for every attempt" do
      Application.put_env(:serviceradar_core, Dgraph,
        item_deadline_ms: 300,
        reply_margin_ms: 1_000
      )

      attach_telemetry([[:serviceradar, :dgraph, :call, :stop]])

      assert {:error, reason} = Dgraph.query("{ q(func: uid(0x1)) { uid } }")
      assert reason =~ "timed out"

      assert_received {:telemetry, [:serviceradar, :dgraph, :call, :stop],
                       %{duration: duration, queue_wait: queue_wait},
                       %{operation: :query_dql, attempt: 1, kind: :timeout}}

      assert duration >= System.convert_time_unit(250, :millisecond, :native)
      assert queue_wait >= 0
    end
  end

  describe "an unreachable Dgraph" do
    setup do
      # Bind and close: nothing listens, so every connect is refused at once.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)
      env_url = System.get_env("DGRAPH_URL")
      previous_config = Application.get_env(:serviceradar_core, Dgraph)
      System.put_env("DGRAPH_URL", "dgraph://127.0.0.1:#{port}?sslmode=disable")

      Application.put_env(:serviceradar_core, Dgraph,
        item_deadline_ms: 2_000,
        bulk_deadline_ms: 2_000,
        max_attempts: 3,
        retry_base_ms: 1,
        retry_max_ms: 5
      )

      on_exit(fn ->
        restore_env("DGRAPH_URL", env_url)
        put_app(Dgraph, previous_config)
      end)

      attach_telemetry([[:serviceradar, :dgraph, :call, :retry]])
      :ok
    end

    test "retries an idempotent upsert, then returns the last error" do
      assert {:error, reason} = Dgraph.upsert_device(%{id: "sr:host01.example.com"})
      assert reason =~ "connect"

      assert_received {:telemetry, [:serviceradar, :dgraph, :call, :retry], %{backoff_ms: _},
                       %{operation: :upsert_device, attempt: 1, kind: :transient}}

      assert_received {:telemetry, [:serviceradar, :dgraph, :call, :retry], _,
                       %{operation: :upsert_device, attempt: 2}}

      refute_received {:telemetry, [:serviceradar, :dgraph, :call, :retry], _, _}
    end

    test "does not retry operations whose repeat is not safe" do
      assert {:error, _} = Dgraph.prune_stale("2030-01-01T00:00:00Z", ["MTR_PATH"])

      assert {:error, _} =
               Dgraph.retire_hosted_edge(
                 "synthetic-guest",
                 "synthetic-host",
                 "2030-01-01T00:00:00Z"
               )

      assert {:error, _} = Dgraph.query("{ q(func: uid(0x1)) { uid } }")
      refute_received {:telemetry, [:serviceradar, :dgraph, :call, :retry], _, _}
    end
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp probe_file_io(path, until, count) do
    if System.monotonic_time(:millisecond) > until do
      count
    else
      probe =
        Task.async(fn ->
          File.write!(path, "probe #{count}")
          File.read!(path)
        end)

      result = Task.yield(probe, 1_000) || Task.shutdown(probe, :brutal_kill)

      assert result == {:ok, "probe #{count}"},
             "file I/O stalled behind stalled Dgraph calls (probe #{count})"

      probe_file_io(path, until, count + 1)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)

  defp restore_env(name, value) when is_binary(value) do
    System.put_env(name, value)
  end

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
