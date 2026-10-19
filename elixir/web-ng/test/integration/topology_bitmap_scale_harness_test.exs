defmodule ServiceRadarWebNG.Topology.ScaleHarnessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapFrame
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapQueryAdmission
  alias ServiceRadarWebNG.Topology.Scale.Client
  alias ServiceRadarWebNG.Topology.Scale.Fixture
  alias ServiceRadarWebNG.Topology.Scale.Meter
  alias ServiceRadarWebNG.Topology.Scale.Revisions
  alias ServiceRadarWebNG.Topology.Scale.Wait

  test "the network consumer rejects stale receipts and inconsistent population totals" do
    metadata = %{
      sequence: 1,
      total: 3,
      dictionary_epoch: "dictionary",
      index_epoch: "index",
      query_digest: "query",
      authority_fingerprint: "authority",
      view_digest: "view",
      source_revision: "source",
      index_revision: "revision"
    }

    tile = %{
      z: 0,
      x: 0,
      y: 0,
      revision: "geometry",
      mask: <<1, 0>>,
      causal: <<3, 3>>,
      availability: <<1, 2>>,
      counts: <<3::little-32, 0::little-32>>
    }

    receipt = %{"z" => 0, "x" => 0, "y" => 0, "revision" => "geometry"}
    bmp = "synthetic-" <> <<0xEE, 0x80, 0x80>>
    nonbmp = "synthetic-" <> <<0xF0, 0x90, 0x80, 0x80>>
    bom = <<0xEF, 0xBB, 0xBF>> <> "synthetic"
    sources = %{bmp => 1, nonbmp => 2, bom => 3, <<0xEF, 0xBB, 0xBF>> => 4}
    metadata = Map.put(metadata, :prefix_sources, sources)
    {:ok, frame} = BitmapFrame.encode(metadata, [tile])
    assert %{kind: :baseline, total: 3, sequence: 1} = Client.decode(envelope(frame), [receipt])
    {:ok, reset} = BitmapFrame.encode(Map.put(metadata, :kind, :reset), [])
    assert %{kind: :reset, sequence: 1} = Client.decode(envelope(reset), [])
    assert_raise MatchError, fn -> Client.decode(envelope(reverse_sources(frame)), [receipt]) end
    assert_raise MatchError, fn -> Client.decode(envelope(frame), [%{receipt | "revision" => "stale"}]) end
    {:ok, inconsistent} = BitmapFrame.encode(%{metadata | total: 4}, [tile])
    assert_raise MatchError, fn -> Client.decode(envelope(inconsistent), [receipt]) end
    assert_raise MatchError, fn -> Client.decode(envelope(frame <> <<0>>), [receipt]) end
  end

  test "a churning normal viewer must not stay blank or behind its replica's published revision for 30 seconds" do
    table = sampler(fn -> {:error, :synthetic_unreachable} end)
    now = System.monotonic_time(:millisecond)
    old = now - 31_000
    :ok = Revisions.observe(table, "synthetic-epoch-a", 7, old - 1_000)
    :ok = Revisions.observe(table, "synthetic-epoch-a", 7, old)
    # A newer revision is dated from the previous read, not from when it was seen.
    :ok = Revisions.observe(table, "synthetic-epoch-a", 8, now - 500)

    stats = %{last_revision: {"synthetic-epoch-a", "7"}, max_normal_gap_ms: 0, frames: 1}

    viewer = %{
      slow: false,
      phase: :churn,
      phase_since: old,
      blank_since: nil,
      held_since: old,
      revisions: table,
      stats: stats
    }

    assert {:stop, {:no_progress, %{gap_ms: gap, basis: :behind, held_revision: ["synthetic-epoch-a", "7"]}}, _} =
             Client.handle_info(:progress, viewer)

    assert gap > 30_000
    assert_receive :progress, 2_000

    # An unhinted replica publishes nothing between reconciliation passes; a
    # viewer holding its latest revision is current, however old that frame is,
    # for as long as a recent read confirms it.
    caught_up = put_in(viewer.stats.last_revision, {"synthetic-epoch-a", "8"})
    assert {:noreply, %{stats: %{max_normal_gap_ms: lag}}} = Client.handle_info(:progress, caught_up)
    assert lag in 500..2_000
    assert_receive :progress, 2_000

    # A later index epoch supersedes every revision of the earlier one.
    :ok = Revisions.observe(table, "synthetic-epoch-b", 1, now)
    assert Revisions.freshness(table, "synthetic-epoch-a", 8) == {:behind, now - 500}
    assert {:noreply, _} = Client.handle_info(:progress, caught_up)
    assert_receive :progress, 2_000

    # A reset viewer shows no membership, even when its replica is idle.
    blank = %{caught_up | blank_since: old, stats: %{caught_up.stats | last_revision: {"synthetic-epoch-b", "1"}}}
    assert {:stop, {:no_progress, %{basis: :blank}}, _} = Client.handle_info(:progress, blank)
    assert_receive :progress, 2_000

    for exempt <- [%{blank | slow: true}, %{blank | phase: :steady}] do
      assert {:noreply, %{stats: %{max_normal_gap_ms: 0}}} = Client.handle_info(:progress, exempt)
      assert_receive :progress, 2_000
    end
  end

  test "lost revision sampling does not certify a held frame as current for more than 30 seconds" do
    now = System.monotonic_time(:millisecond)
    old = now - 31_000
    failing = fn -> {:error, :synthetic_unreachable} end

    viewer = fn table, epoch ->
      stats = %{last_revision: {epoch, "7"}, max_normal_gap_ms: 0, frames: 1}

      %{
        slow: false,
        phase: :churn,
        phase_since: old,
        blank_since: nil,
        held_since: old,
        revisions: table,
        stats: stats
      }
    end

    # Reads confirmed revision 7 long ago and every read since has failed.
    stale = sampler(failing, :stale)
    :ok = Revisions.observe(stale, "synthetic-epoch-a", 7, old)

    assert {:stop, {:no_progress, %{basis: :current, gap_ms: gap, sampler: %{failures: failures}}}, _} =
             Client.handle_info(:progress, viewer.(stale, "synthetic-epoch-a"))

    assert gap > 30_000 and failures >= 1
    assert_receive :progress, 2_000

    # No read has ever succeeded, so nothing establishes the held revision.
    empty = sampler(failing, :empty)

    assert {:stop, {:no_progress, %{basis: :unobserved, sampler: %{last_read_age_ms: nil}}}, _} =
             Client.handle_info(:progress, viewer.(empty, "synthetic-epoch-a"))

    assert_receive :progress, 2_000

    # Reads succeed, but never for the epoch this viewer holds.
    unknown = sampler(fn -> {:ok, {"synthetic-epoch-c", 3}} end, :unknown)

    assert {:stop, {:no_progress, %{basis: :unobserved, gap_ms: gap}}, _} =
             Client.handle_info(:progress, viewer.(unknown, "synthetic-epoch-z"))

    assert gap > 30_000
    assert_receive :progress, 2_000

    # A frame the sampler has not reached yet is a bounded race, not a stall.
    fresh = %{viewer.(unknown, "synthetic-epoch-z") | held_since: now}
    assert {:noreply, %{stats: %{max_normal_gap_ms: lag}}} = Client.handle_info(:progress, fresh)
    assert lag < 30_000
    assert_receive :progress, 2_000
  end

  test "a stopped viewer fails the driver at once with only its own bounded report" do
    report = %{
      gap_ms: 30_500,
      basis: :behind,
      sampler: %{failures: 0, last_read_age_ms: 200},
      held_revision: ["synthetic-epoch", "7"],
      stats: %{frames: 4}
    }

    viewers =
      for {id, reason} <- [{0, {:no_progress, report}}, {1, {%RuntimeError{message: "synthetic-cookie-value"}, []}}] do
        pid = spawn(fn -> receive(do: (:stop -> exit(reason))) end)
        %{id: id, pid: pid, opts: [slow: false], monitor: Process.monitor(pid)}
      end

    other = spawn(fn -> :ok end)
    unrelated = Process.monitor(other)
    diagnose = fn -> Wait.diagnostics(viewers, [], 300) end
    await_down(%{pid: other})
    assert Wait.viewers_alive!(viewers, diagnose) == :ok

    for {viewer, expected} <-
          Enum.zip(viewers, [
            %{
              "kind" => "no_progress",
              "gap_ms" => 30_500,
              "basis" => "behind",
              "sampler" => %{"failures" => 0, "last_read_age_ms" => 200},
              "held_revision" => ["synthetic-epoch", "7"],
              "stats" => %{"frames" => 4}
            },
            %{"kind" => "RuntimeError"}
          ]) do
      send(viewer.pid, :stop)

      output =
        capture_io(fn ->
          assert_raise ExUnit.AssertionError, ~r/viewer #{viewer.id} exited/, fn ->
            await_down(viewer)
            Wait.viewers_alive!(viewers, diagnose)
          end
        end)

      assert [failed, waited] =
               output
               |> String.split("\n", trim: true)
               |> Enum.map(&Jason.decode!(String.trim_leading(&1, "TOPOLOGY_BITMAP_SCALE ")))

      assert failed["phase"] == "viewer_failed" and failed["viewer"] == viewer.id
      assert failed["failure"] == expected
      assert waited["phase"] == "wait_failed"
      refute output =~ "synthetic-cookie-value"
    end

    # A monitor the driver does not own stays queued for its owner.
    assert_received {:DOWN, ^unrelated, :process, ^other, _}
  end

  test "a refused socket upgrade stops the viewer without logging its session" do
    {:ok, _} = Application.ensure_all_started(:gun)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")

        receive do
          :done -> :gen_tcp.close(socket)
        end
      end)

    session = %{port: port, cookie: "_synthetic_key=synthetic-cookie-value", csrf: "synthetic-csrf-value"}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = GenServer.start(Client, session: session, tiles: [], revisions: :ets.new(:revisions, []))
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, {:upgrade_refused, 403}}, 10_000
      end)

    send(server, :done)
    :gen_tcp.close(listen)
    assert log =~ "upgrade_refused"
    refute log =~ "synthetic-cookie-value"
    refute log =~ "synthetic-csrf-value"
  end

  test "a failed read reports every viewer within one budget and keeps the original exit" do
    live =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :report} -> GenServer.reply(from, %{frames: 3, last_revision: "synthetic-revision"})
        end
      end)

    dead = spawn(fn -> :ok end)
    stalled = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(stalled, :kill) end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    viewers =
      for {pid, id} <- [{stalled, 0}, {dead, 1}, {live, 2}], do: %{id: id, pid: pid, opts: [slow: id == 0]}

    replicas = [{:a, fn -> exit(:peer_down) end}, {:b, fn -> Process.sleep(:infinity) end}]
    diagnose = fn -> Wait.diagnostics(viewers, replicas, 300) end
    started = System.monotonic_time(:millisecond)

    output =
      capture_io(fn ->
        assert catch_exit(Wait.until(fn -> GenServer.call(dead, :report) end, & &1, started + 60_000, "views", diagnose)) ==
                 {:noproc, {GenServer, :call, [dead, :report, 5_000]}}
      end)

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert ["TOPOLOGY_BITMAP_SCALE " <> json] = String.split(output, "\n", trim: true)
    record = Jason.decode!(json)
    assert record["phase"] == "wait_failed" and record["wait"] == "views"
    assert [stalled_row, dead_row, live_row] = record["viewers"]
    assert stalled_row == %{"viewer" => 0, "slow" => true, "timed_out" => true}
    assert dead_row == %{"viewer" => 1, "slow" => false, "down" => true}
    assert live_row == %{"viewer" => 2, "slow" => false, "frames" => 3}
    assert record["replicas"] == [%{"replica" => "a", "unavailable" => "exit"}, %{"replica" => "b", "timed_out" => true}]

    broken = fn -> raise "synthetic diagnostic failure" end

    capture_io(fn ->
      assert catch_throw(Wait.until(fn -> throw(:read_failed) end, & &1, started + 60_000, "views", broken)) ==
               :read_failed
    end)
  end

  test "synthetic geometry really partitions admitted leaf and aggregate rows" do
    world = Fixture.world("synthetic-acceptance-layout", 8_256)

    for y <- 0..7, x <- 0..7 do
      assert {:ok, tile} = TopologyAtlas.tile(world, 3, x, y)
      assert length(tile.glyphs) == 128
      assert Enum.count(tile.glyphs, &(&1.kind == :device)) == 127
      assert Enum.count(tile.glyphs, &(&1.kind == :aggregate)) == 1
    end
  end

  test "the database meter survives transaction events and reports a detached handler" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    start_supervised!(Meter)
    event = Keyword.fetch!(ServiceRadar.Repo.config(), :telemetry_prefix) ++ [:query]

    # Ecto's commit event: Postgrex reports num_rows nil and decode time is unmeasured.
    commit = %{query: "commit", options: [], result: {:ok, %Postgrex.Result{command: :commit, num_rows: nil}}}
    :telemetry.execute(event, %{query_time: 532, decode_time: nil}, commit)

    select = %{query: "SELECT 1", options: [], result: {:ok, %Postgrex.Result{command: :select, num_rows: 3}}}
    :telemetry.execute(event, %{query_time: 1, decode_time: 1, queue_time: 1}, select)

    # Bitmap query rejections are counted by origin and admitted work by
    # wait/run bucket, from the production emitters the replicas run.
    start_supervised!(BitmapQueries)
    BitmapQueries.busy(:pin_budget)
    BitmapQueries.busy(:pin_budget)
    BitmapQueries.busy(:admission_expired)
    assert {:ok, :ran} = BitmapQueryAdmission.run(fn -> :ran end, System.monotonic_time(:millisecond) + 1_000)

    report = Meter.report()
    assert report.instrumented
    assert %{queries: 2, rows: 3} = report.database.other
    assert report.queries.busy == %{pin_budget: 2, admission_expired: 1}
    assert report.queries.wait_ms |> Map.values() |> Enum.sum() == 1
    assert report.queries.run_ms |> Map.values() |> Enum.sum() == 1

    :ok = :telemetry.detach(Meter)
    refute Meter.report().instrumented
  end

  test "isolated peer VMs load declared harness beams and expose actual Linux RSS" do
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

      for {module, binary} <- Application.fetch_env!(:serviceradar_web_ng, :topology_scale_modules) do
        assert {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, ~c"scale-fixture", binary])
      end

      memory = :peer.call(peer, Meter, :memory, [])
      assert memory.rss > 0
      assert memory.rss_high_water >= memory.rss
      assert memory.native_unavailable == 1
      assert memory.mapping_unavailable == 1
    after
      :peer.stop(peer)
    end
  end

  # Waits on a separate monitor so the driver's own DOWN stays queued for it.
  defp await_down(viewer) do
    ref = Process.monitor(viewer.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  defp envelope(frame), do: <<0, 1, 14, 16, "1topology:tilesmembership:frame", frame::binary>>

  defp reverse_sources(frame) do
    <<"SRMO", 1, kind, 0::little-16, size::little-32, sequence::little-64, total::little-32, rest::binary>> = frame
    {prefix, rest} = drop_texts(rest, 7)
    <<count, rest::binary>> = rest

    <<len1::little-16, first::binary-size(len1), ver1::binary-size(8), len2::little-16, second::binary-size(len2),
      ver2::binary-size(8), rest::binary>> = rest

    <<
      "SRMO",
      1,
      kind,
      0::little-16,
      size::little-32,
      sequence::little-64,
      total::little-32,
      prefix::binary,
      count,
      len2::little-16,
      second::binary,
      ver2::binary,
      len1::little-16,
      first::binary,
      ver1::binary,
      rest::binary
    >>
  end

  defp drop_texts(rest, 0), do: {"", rest}

  defp drop_texts(<<length::little-16, rest::binary>>, count) do
    <<value::binary-size(length), rest::binary>> = rest
    {tail, rest} = drop_texts(rest, count - 1)
    {<<length::little-16, value::binary, tail::binary>>, rest}
  end

  # The sampler's first read runs before it answers, so its table always holds
  # at least one read outcome.
  defp sampler(read, id \\ :revisions) do
    {Revisions, read} |> Supervisor.child_spec(id: id) |> start_supervised!() |> Revisions.table()
  end
end
