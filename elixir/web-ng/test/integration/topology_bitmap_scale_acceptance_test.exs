defmodule ServiceRadarWebNG.Topology.ScaleAcceptanceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.Scale.Client
  alias ServiceRadarWebNG.Topology.Scale.Fixture
  alias ServiceRadarWebNG.Topology.Scale.Replica

  @moduletag :topology_bitmap_scale
  # Leave one minute for peer teardown inside the hosted 2,700-second test budget.
  @moduletag timeout: 2_640_000

  test "two database publishers converge while 100 actual socket views consume bounded replacements" do
    distribution =
      case System.fetch_env!("TOPOLOGY_BITMAP_SCALE_ORDINALS") do
        "compact" -> :compact
        "sparse" -> :sparse
      end

    started = now()
    {:ok, tracker} = Agent.start(fn -> %{seeded: false, ordinal_seq: nil} end)

    on_exit(fn ->
      try do
        Fixture.cleanup!(Agent.get(tracker, & &1))
      after
        Agent.stop(tracker)
      end
    end)

    fixture = Fixture.seed(distribution, tracker)

    emit(
      "fixture",
      Map.merge(fixture, %{
        seed_ms: now() - started,
        infrastructure: 100_000,
        endpoints: 1_000_000,
        ticks: 100,
        cadence_ms: 5_000,
        viewers: 100,
        slow_viewers: 10,
        geometry: "synthetic native world; excludes layout/persistence",
        transport: "Gun; excludes browser/GPU"
      })
    )

    actor = SystemActor.system(:topology_bitmap_scale)

    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "atlas-scale@example.com", role: :viewer}, actor: actor)
      |> Ash.create!()

    # Fail here, not as a later tile 403, if the clone lacks the catalog's viewer profile.
    assert {:ok, _scope} = RBAC.authorize_current(Scope.for_user(user), ["analytics.view", "devices.view"])

    config = Enum.map(Application.loaded_applications(), fn {app, _, _} -> {app, Application.get_all_env(app)} end)
    first = start_replica(config, user)
    on_exit(fn -> stop_replica(first) end)
    second = start_replica(config, user)
    on_exit(fn -> stop_replica(second) end)
    machines = Enum.map([first, second], & &1.session.machine)
    assert Enum.all?(machines, &(&1.schedulers == 4 and &1.dirty_cpu_schedulers == 4))
    emit("machines", %{replicas: machines})

    # Preflight the real WebSocket upgrade boundary with as many concurrently
    # open sockets as the scenario holds per server, before the fleet run.
    for replica <- [first, second] do
      outcomes = Client.upgrades(replica.session, 50)
      assert Enum.frequencies(outcomes) == %{upgraded: 50}
    end

    for replica <- [first, second] do
      await(fn -> call(replica, :progress) end, &match?({:ok, _}, &1), 600_000, "publisher seed")
      {elapsed, mapping} = timed(fn -> call(replica, :install_geometry, [], 600_000) end)
      assert mapping.mapped == Fixture.population()
      emit("geometry", %{replica: replica.id, ms: elapsed, mapping: mapping})
    end

    sessions = [first.session, second.session]
    receipts = Enum.map(sessions, &Client.receipts/1)

    clients =
      for index <- 0..99 do
        side = rem(index, 2)
        opts = [session: Enum.at(sessions, side), tiles: Enum.at(receipts, side), slow: rem(index, 11) == 0]
        pid = start_supervised!(Supervisor.child_spec({Client, opts}, id: {:view, index}, restart: :temporary))
        %{id: index, pid: pid, opts: opts}
      end

    replicas = [first, second]

    await(
      fn -> reports(clients) end,
      &Enum.all?(&1, fn row -> row.frames > 0 end),
      90_000,
      "initial 100 views",
      diagnose(clients, replicas)
    )

    Enum.each(clients, &Client.phase(&1.pid, :churn))
    emit("warmup", %{clients: summarize(reports(clients)), replicas: metrics([first, second])})

    # Hints go only to A. B must repair every write through its ordinary rolling
    # scan; no injected rescan event or timestamp watermark assists it.
    replacement =
      Task.async(fn ->
        receive do
          :replace -> timed(fn -> call(first, :replace_mapping, [], 600_000) end)
        after
          1_200_000 -> raise "mapping replacement never started"
        end
      end)

    tick_samples =
      for tick <- 0..99 do
        tick_start = now()
        {write_ms, total} = timed(fn -> Fixture.churn(tick, &call(first, :hint, [&1])) end)

        if tick == 30, do: send(replacement.pid, :replace)

        if tick == 60 do
          clients |> Enum.filter(&(rem(&1.id, 2) == 1)) |> Enum.each(&Client.phase(&1.pid, :recovery))
          :ok = call(second, :restart_index, [], 15_000)
          emit("index_restart", %{tick: tick})
        end

        if tick > 60 and match?({:ok, _}, call(second, :progress)) do
          clients |> Enum.filter(&(rem(&1.id, 2) == 1)) |> Enum.each(&Client.phase(&1.pid, :churn))
        end

        emit("tick", %{
          tick: tick,
          write_ms: write_ms,
          tick_work_ms: now() - tick_start,
          expected_total: total,
          replicas: metrics([first, second])
        })

        facets = for n <- 0..49, do: %{"facet" => "tag:cohort", "value" => "cohort-#{n}"}
        {latency, {status, result}} = timed(fn -> query(Enum.at(sessions, rem(tick, 2)), %{"facets" => facets}) end)

        if status == 200 do
          assert length(result["facets"]) == 50
          assert Enum.sum(Enum.map(result["facets"], & &1["count"])) == result["total"]
        else
          assert status == 503
        end

        emit("query_with_facets", %{
          tick: tick,
          latency_ms: latency,
          tick_work_ms: now() - tick_start,
          status: status,
          error: result["error"]
        })

        Process.sleep(max(5_000 - (now() - tick_start), 0))
        %{write_ms: write_ms, query_ms: latency, status: status}
      end

    {mapping_ms, mapping} = Task.await(replacement, 600_000)
    emit("mapping_replacement", %{ms: mapping_ms, mapping: mapping, replicas: metrics([first, second])})

    Enum.each(clients, &Client.phase(&1.pid, :steady))
    # Cold-restart recovery is bounded separately from ordinary ready-operation
    # progress; if seeding is still underway, retain its explicit recovery phase.
    if not match?({:ok, _}, call(second, :progress)) do
      clients |> Enum.filter(&(rem(&1.id, 2) == 1)) |> Enum.each(&Client.phase(&1.pid, :recovery))
    end

    expected = Fixture.expected_total()
    assert expected == Fixture.population()

    {converge_ms, _} =
      timed(fn ->
        for session <- sessions do
          await(
            fn -> query(session) end,
            &match?({200, %{"total" => ^expected}}, &1),
            600_000,
            "final database convergence"
          )
        end
      end)

    await(
      fn -> reports(clients) end,
      &Enum.all?(&1, fn row -> row.latest_total == expected end),
      90_000,
      "final wire convergence",
      diagnose(clients, replicas)
    )

    Enum.each(clients, &Client.phase(&1.pid, :steady))

    # Actual reconnects create new sockets and require new accepted replacements.
    previous = clients |> Enum.take(10) |> reports()

    clients =
      Enum.map(clients, fn client ->
        if client.id < 10 do
          :ok = stop_supervised({:view, client.id})

          %{
            client
            | pid:
                start_supervised!(
                  Supervisor.child_spec({Client, client.opts}, id: {:view, client.id}, restart: :temporary)
                )
          }
        else
          client
        end
      end)

    await(
      fn -> reports(clients) end,
      &Enum.all?(&1, fn row -> row.latest_total == expected end),
      90_000,
      "reconnected views",
      diagnose(clients, replicas)
    )

    Enum.each(clients, &Client.phase(&1.pid, :steady))

    {200, page} = query(hd(sessions))
    assert is_binary(page["cursor"])
    {200, next_page} = query(List.last(sessions), %{"cursor" => page["cursor"]})
    assert next_page["total"] == expected
    assert hd(next_page["ordinals"]) > hd(page["ordinals"])

    for session <- sessions,
        {cidr, total} <- [{"2001:db8:2::/48", expected}, {"2001:db8:1::/48", 0}, {"198.51.100.7/32", expected}] do
      expression = %{"all" => [%{"facet" => "tag:scale", "value" => "fixture"}, %{"ip_cidr" => cidr}]}

      await(
        fn -> query(session, %{"expression" => expression}) end,
        &match?({200, %{"total" => ^total}}, &1),
        30_000,
        "complete primary-address replacement"
      )
    end

    Fixture.oversize_facet_value()
    unavailable = %{"expression" => %{"facet" => "tag:cohort", "value" => "cohort-0"}, "limit" => 1}

    for session <- sessions do
      await(
        fn -> request_query(session, unavailable) end,
        &match?({422, %{"error" => "facet_unavailable"}}, &1),
        600_000,
        "oversized facet value refusal"
      )
    end

    final = reports(clients)
    assert Enum.all?(final, &(&1.frames > 0 and &1.max_frame_bytes <= 262_144))

    await(
      fn -> clients |> reports() |> Enum.take_every(11) end,
      &Enum.all?(&1, fn row -> row.slow_resets > 0 end),
      30_000,
      "every slow viewer reset",
      diagnose(clients, replicas)
    )

    final = reports(clients)
    successful_queries = Enum.filter(tick_samples, &(&1.status == 200))
    assert successful_queries != []
    samples = metrics([first, second])

    for sample <- samples do
      assert sample.instrumented
      assert sample.samples > 100
      assert sample.latest.native_unavailable == 0
      assert sample.latest.mapping_unavailable == 0
      assert sample.peaks.native_bytes <= 160_000_000
      assert sample.peaks.native_peak_bytes <= 160_000_000
      assert sample.peaks.current_mapping_bytes <= 33_554_432
      assert sample.peaks.pins <= 8
      assert sample.peaks.rss > 0
      assert %{queries: address_queries, rows: address_rows} = sample.database.addresses
      assert address_queries > 0 and address_rows > 0
    end

    emit("combined", %{
      tick_write_ms: percentiles(Enum.map(tick_samples, & &1.write_ms)),
      query_with_facets_ms: percentiles(Enum.map(successful_queries, & &1.query_ms)),
      query_http_statuses: Enum.frequencies_by(tick_samples, & &1.status),
      convergence_ms: converge_ms,
      clients: summarize(previous ++ final),
      viewers:
        Enum.zip_with(clients, final, fn client, row ->
          row |> Map.drop([:latency_ms, :last_revision, :last_frame_at, :last_fresh_at]) |> Map.put(:viewer, client.id)
        end),
      replicas: samples,
      elapsed_ms: now() - started,
      cluster_rss_sample: Enum.sum(Enum.map(samples, & &1.latest.rss)),
      cluster_rss_peak_upper: Enum.sum(Enum.map(samples, & &1.peaks.rss_high_water))
    })

    Enum.each(clients, &Client.phase(&1.pid, :recovery))
    before_revocation = reports(clients)
    user |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor) |> Ash.update!()

    for session <- sessions do
      path = "/topology/tiles/#{session.version}/3/0/0"

      await(
        fn ->
          {status, _headers, _body} = Client.http(session, "GET", path)
          status
        end,
        &(&1 in [401, 403]),
        15_000,
        "authority revocation"
      )
    end

    await(
      fn -> reports(clients) end,
      fn after_revocation ->
        before_revocation
        |> Enum.zip(after_revocation)
        |> Enum.all?(fn {before, after_row} ->
          Map.get(after_row.errors, "forbidden", 0) > Map.get(before.errors, "forbidden", 0)
        end)
      end,
      15_000,
      "socket authority revocation",
      diagnose(clients, replicas)
    )

    emit("revoked", %{clients: summarize(reports(clients))})
  end

  defp start_replica(config, user) do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"4:4", ~c"+SDcpu", ~c"4"]})
    Process.unlink(peer)

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

      for {module, binary} <- Application.fetch_env!(:serviceradar_web_ng, :topology_scale_modules) do
        {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, ~c"scale-fixture", binary])
      end

      session = :peer.call(peer, Replica, :start, [config, user], 30_000)
      %{peer: peer, session: session, id: session.port}
    catch
      kind, reason ->
        stop_peer(peer)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp stop_replica(replica) do
    call(replica, :stop, [], 15_000)
  catch
    :exit, _ -> :ok
  after
    stop_peer(replica.peer)
  end

  defp stop_peer(peer) do
    monitor = Process.monitor(peer)
    if Process.alive?(peer), do: :peer.stop(peer)
    assert_receive {:DOWN, ^monitor, :process, ^peer, _reason}, 15_000
  end

  defp call(replica, function, args \\ [], timeout \\ 10_000),
    do: :peer.call(replica.peer, Replica, function, args, timeout)

  defp query(session, extra \\ %{}),
    do: request_query(session, Map.merge(%{"expression" => Fixture.query(), "limit" => 1}, extra))

  defp request_query(session, params) do
    {status, _headers, bytes} = Client.http(session, "POST", "/topology/query", Jason.encode!(params))
    {status, Jason.decode!(bytes)}
  end

  defp reports(clients), do: Enum.map(clients, &Client.report(&1.pid))
  defp metrics(replicas), do: Enum.map(replicas, &Map.put(call(&1, :report), :replica, &1.id))

  defp timed(fun) do
    start = now()
    result = fun.()
    {now() - start, result}
  end

  defp await(read, predicate, timeout, label, diagnose \\ nil),
    do: await_until(read, predicate, now() + timeout, label, diagnose)

  defp await_until(read, predicate, deadline, label, diagnose) do
    result = read.()

    cond do
      predicate.(result) ->
        result

      now() >= deadline ->
        if diagnose, do: emit("wait_failed", Map.put(diagnose.(), :wait, label))
        flunk("#{label} did not complete: #{inspect(result, limit: 20)}")

      true ->
        Process.sleep(500)
        await_until(read, predicate, deadline, label, diagnose)
    end
  end

  # Every viewer's own counters and both replicas' meters, so a failed wait shows
  # which views stalled and why. Reports carry no session, cookie or CSRF value.
  defp diagnose(clients, replicas) do
    fn ->
      %{
        viewers:
          Enum.map(clients, fn client ->
            try do
              client.pid
              |> Client.report()
              |> Map.drop([:latency_ms, :last_revision, :last_frame_at, :last_fresh_at])
              |> Map.merge(%{viewer: client.id, slow: client.opts[:slow]})
            catch
              :exit, _ -> %{viewer: client.id, down: true}
            end
          end),
        replicas:
          Enum.map(replicas, fn replica ->
            try do
              Map.put(call(replica, :report), :replica, replica.id)
            catch
              :exit, _ -> %{replica: replica.id, unavailable: true}
            end
          end)
      }
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp emit(phase, values), do: IO.puts("TOPOLOGY_BITMAP_SCALE " <> Jason.encode!(Map.put(values, :phase, phase)))

  defp percentiles(values) do
    sorted = Enum.sort(values)

    Map.new(
      [50, 95, 99],
      &{Integer.to_string(&1), Enum.at(sorted, min(div(length(sorted) * &1, 100), length(sorted) - 1))}
    )
  end

  defp summarize(rows) do
    histogram = Enum.reduce(rows, %{}, &Map.merge(&2, &1.latency_ms, fn _, a, b -> a + b end))
    latencies = Enum.flat_map(histogram, fn {value, count} -> List.duplicate(value, count) end)

    %{
      frames: Enum.sum(Enum.map(rows, & &1.frames)),
      requests: Enum.sum(Enum.map(rows, & &1.requests)),
      bytes: Enum.sum(Enum.map(rows, & &1.bytes)),
      max_frame_bytes: Enum.max(Enum.map(rows, & &1.max_frame_bytes)),
      resets: Enum.sum(Enum.map(rows, & &1.resets)),
      slow_resets: Enum.sum(Enum.map(rows, & &1.slow_resets)),
      max_slow_reset_ms: Enum.max(Enum.map(rows, & &1.max_slow_reset_ms)),
      max_normal_gap_ms: Enum.max(Enum.map(rows, & &1.max_normal_gap_ms)),
      retries: Enum.sum(Enum.map(rows, & &1.retries)),
      latency_ms: percentiles(latencies),
      errors: Enum.reduce(rows, %{}, &Map.merge(&2, &1.errors, fn _, a, b -> a + b end))
    }
  end
end
