defmodule ServiceRadarWebNG.BitmapTransportTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.BitmapTransport.Fixture
  alias ServiceRadarWebNG.BitmapTransport.Server

  @moduletag :db_free
  @moduletag timeout: 600_000
  @warmup 5
  @samples 30

  test "real Phoenix upgrades preserve SRMO frames under concurrent compression" do
    for distribution <- [:uniform, :mixed], clients <- [1, 10, 100] do
      frames = Fixture.frames(distribution, @warmup + @samples)

      for compressed <- [false, true] do
        result = run_case(frames, clients, compressed, true)
        IO.puts("ATLAS_WEBSOCKET_TRANSPORT " <> Jason.encode!(Map.put(result, :distribution, distribution)))
      end
    end

    run_case(Fixture.frames(:mixed, @warmup + @samples), 1, true, false)
  end

  defp run_case(frames, clients, compressed, offer) do
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"4:4"]})
    monitor = Process.monitor(peer)

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:phoenix])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:bandit])

      for {module, beam} <- :persistent_term.get(:bitmap_transport_support) do
        {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, ~c"bitmap_transport_support", beam])
      end

      server = :peer.call(peer, Server, :start, [frames])
      empty = :peer.call(peer, Server, :resources, [])
      owner = self()

      tasks =
        for _ <- 1..clients do
          Task.async(fn -> client(owner, server.port, frames, compressed, offer) end)
        end

      for _ <- tasks do
        assert_receive {:ready, _pid}, 30_000
      end

      before_run = :peer.call(peer, Server, :resources, [])
      started = System.monotonic_time(:microsecond)
      Enum.each(tasks, &send(&1.pid, :measure))
      results = Enum.map(tasks, &Task.await(&1, 120_000))
      elapsed_us = System.monotonic_time(:microsecond) - started
      after_run = :peer.call(peer, Server, :resources, [])
      closed = :peer.call(peer, Server, :closed, [clients], 15_000)
      assert %{connections: ^clients, frames: frame_count, bytes: payload_bytes, errors: 0} = closed
      assert frame_count == clients * (@warmup + @samples)
      latencies = results |> Enum.flat_map(& &1.latencies) |> Enum.sort()
      [extension] = results |> Enum.map(& &1.extension) |> Enum.uniq()
      wire_bytes = byte_size(Map.fetch!(frames, 1)) + 35
      expected_bytes = clients * (@warmup + @samples) * wire_bytes
      negotiated = compressed and offer
      if negotiated, do: assert(payload_bytes < expected_bytes), else: assert(payload_bytes == expected_bytes)

      %{
        clients: clients,
        compression_enabled: compressed,
        negotiated: negotiated,
        negotiated_extension: extension,
        schedulers: server.schedulers,
        otp: server.otp,
        phoenix: server.phoenix,
        bandit: server.bandit,
        gun: List.to_string(Application.spec(:gun, :vsn)),
        samples_per_client: @samples,
        warmup_per_client: @warmup,
        wire_bytes: wire_bytes,
        payload_bytes_including_warmup: payload_bytes,
        uncompressed_bytes_including_warmup: expected_bytes,
        wall_ms: elapsed_us / 1000,
        frames_per_second: clients * @samples * 1_000_000 / elapsed_us,
        roundtrip_p50_us: Enum.at(latencies, div(length(latencies), 2)),
        roundtrip_p95_us: Enum.at(latencies, ceil(length(latencies) * 0.95) - 1),
        server_vm_runtime_ms: after_run.cpu_ms - before_run.cpu_ms,
        server_process_cpu_ms: after_run.os_cpu_ms - before_run.os_cpu_ms,
        server_process_user_ticks: after_run.os_user_ticks - before_run.os_user_ticks,
        server_process_system_ticks: after_run.os_system_ticks - before_run.os_system_ticks,
        server_os_ticks_per_second: after_run.os_ticks_per_second,
        server_empty_rss_bytes: empty.rss_bytes,
        server_connected_rss_bytes: before_run.rss_bytes,
        server_after_rss_bytes: after_run.rss_bytes,
        server_peak_rss_bytes: after_run.peak_rss_bytes,
        server_beam_bytes: after_run.beam_bytes,
        closed_connections: closed.connections
      }
    after
      :peer.stop(peer)
      assert_receive {:DOWN, ^monitor, :process, ^peer, :normal}, 10_000
    end
  end

  defp client(owner, port, frames, compressed, offer) do
    {:ok, connection} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http], retry: 0})
    monitor = Process.monitor(connection)

    try do
      {:ok, :http} = :gun.await_up(connection)
      path = if compressed, do: "/compressed/websocket?vsn=2.0.0", else: "/plain/websocket?vsn=2.0.0"
      stream = :gun.ws_upgrade(connection, path, [], %{compress: offer})

      assert_receive {:gun_upgrade, ^connection, ^stream, ["websocket"], headers}, 10_000
      extension = List.keyfind(headers, "sec-websocket-extensions", 0)
      negotiated = not is_nil(extension)
      assert negotiated == (compressed and offer)
      if extension, do: assert(String.starts_with?(elem(extension, 1), "permessage-deflate"))
      :ok = :gun.ws_send(connection, stream, {:text, Jason.encode!(["1", "1", "topology:tiles", "phx_join", %{}])})
      assert_receive {:gun_ws, ^connection, ^stream, {:text, joined}}, 10_000
      assert ["1", "1", "topology:tiles", "phx_reply", %{"status" => "ok"}] = Jason.decode!(joined)
      for sequence <- 1..@warmup, do: exchange(connection, stream, sequence, frames)
      send(owner, {:ready, self()})

      receive do
        :measure -> :ok
      after
        30_000 -> flunk("concurrent measurement did not start")
      end

      sequences = (@warmup + 1)..(@warmup + @samples)
      latencies = Enum.map(sequences, &exchange(connection, stream, &1, frames))
      :ok = :gun.ws_send(connection, stream, {:close, 1000, <<>>})
      assert_receive {:gun_ws, ^connection, ^stream, {:close, 1000, _}}, 10_000
      %{latencies: latencies, extension: if(extension, do: elem(extension, 1))}
    after
      :gun.close(connection)
      assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 10_000
    end
  end

  defp exchange(connection, stream, sequence, frames) do
    request = Jason.encode!(["1", "2", "topology:tiles", "next", %{sequence: sequence}])
    started = System.monotonic_time(:microsecond)
    :ok = :gun.ws_send(connection, stream, {:text, request})
    assert_receive {:gun_ws, ^connection, ^stream, {:binary, wire}}, 30_000
    elapsed = System.monotonic_time(:microsecond) - started
    expected = Map.fetch!(frames, sequence)
    assert <<0, 1, 14, 16, "1topology:tilesmembership:frame", ^expected::binary>> = wire
    elapsed
  end
end
