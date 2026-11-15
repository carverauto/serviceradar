defmodule ServiceRadarObjectStorage.BenchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import Bitwise

  alias ServiceRadarObjectStorage.Session

  @bucket "synthetic-bench"
  @region "us-east-1"
  @access_key "SYNTHETICBENCHKEY01"
  @secret_key "synthetic-bench-secret-access-key-000001"
  @etag ~s("synthetic-bench-etag-v1")
  @version "bench-v1"
  @dummy_sha256 :binary.copy(<<0x42>>, 32)

  @cells [
    %{op: :put, size: 4_096, range_len: 4_096, concurrency: 1, buffer_size: 65_536},
    %{op: :put, size: 4_096, range_len: 4_096, concurrency: 8, buffer_size: 65_536},
    %{op: :put, size: 1_048_576, range_len: 1_048_576, concurrency: 1, buffer_size: 1_048_576},
    %{op: :put, size: 1_048_576, range_len: 1_048_576, concurrency: 4, buffer_size: 1_048_576},
    %{op: :put, size: 4_194_304, range_len: 4_194_304, concurrency: 1, buffer_size: 4_194_304},
    %{op: :put, size: 4_194_304, range_len: 4_194_304, concurrency: 4, buffer_size: 4_194_304},
    %{op: :put, size: 4_194_304, range_len: 4_194_304, concurrency: 16, buffer_size: 4_194_304},
    %{op: :put, size: 16_777_216, range_len: 16_777_216, concurrency: 1, buffer_size: 16_777_216},
    %{op: :put, size: 16_777_216, range_len: 16_777_216, concurrency: 4, buffer_size: 16_777_216},
    %{op: :head, size: 4_194_304, range_len: 0, concurrency: 4, buffer_size: 65_536},
    %{op: :get_range, size: 1_048_576, range_len: 4_096, concurrency: 4, buffer_size: 65_536},
    %{op: :get_range, size: 4_194_304, range_len: 1_048_576, concurrency: 4, buffer_size: 1_048_576},
    %{op: :get_range, size: 16_777_216, range_len: 4_194_304, concurrency: 1, buffer_size: 4_194_304},
    %{op: :get_range, size: 16_777_216, range_len: 4_194_304, concurrency: 4, buffer_size: 4_194_304}
  ]

  @tag timeout: 900_000
  test "runs interleaved paired native and Rustler NIF benchmarks against controlled loopback S3 peer" do
    bench_bin = resolve_bench_binary!()
    reps = env_int("LONGSHORE_BENCH_REPS", 5)
    warmup_ms = env_int("LONGSHORE_BENCH_WARMUP_MS", 300)
    duration_ms = env_int("LONGSHORE_BENCH_DURATION_MS", 1_000)

    {peer_port_handle, tcp_port} = start_peer!(bench_bin)
    on_exit(fn -> safe_close_port(peer_port_handle) end)

    seed = build_seed_binary(16_777_216)
    env_meta = host_environment()
    IO.puts("BENCH_HOST_JSON=" <> encode_json(env_meta))

    summaries =
      Enum.map(@cells, fn cell ->
        summary = run_paired_cell(bench_bin, tcp_port, seed, cell, reps, warmup_ms, duration_ms)
        IO.puts("BENCH_SUMMARY_JSON=" <> encode_json(summary))
        summary
      end)

    assert length(summaries) == length(@cells)
    assert Enum.all?(summaries, &(&1.nif_median_ops_per_s > 0.0 and &1.native_median_ops_per_s > 0.0))
  end

  defp run_paired_cell(bench_bin, tcp_port, seed, cell, reps, warmup_ms, duration_ms) do
    pairs =
      Enum.map(1..reps, fn rep ->
        if rem(rep, 2) == 1 do
          native = run_native_cell!(bench_bin, tcp_port, cell, warmup_ms, duration_ms)
          nif = run_nif_cell!(tcp_port, seed, cell, warmup_ms, duration_ms, rep)
          {native, nif}
        else
          nif = run_nif_cell!(tcp_port, seed, cell, warmup_ms, duration_ms, rep)
          native = run_native_cell!(bench_bin, tcp_port, cell, warmup_ms, duration_ms)
          {native, nif}
        end
      end)

    summarize_pairs(cell, pairs)
  end

  defp run_native_cell!(bench_bin, tcp_port, cell, warmup_ms, duration_ms) do
    args = [
      "native",
      "--port",
      Integer.to_string(tcp_port),
      "--op",
      Atom.to_string(cell.op),
      "--size",
      Integer.to_string(cell.size),
      "--range-len",
      Integer.to_string(max(cell.range_len, 1)),
      "--concurrency",
      Integer.to_string(cell.concurrency),
      "--buffer-size",
      Integer.to_string(cell.buffer_size),
      "--warmup-ms",
      Integer.to_string(warmup_ms),
      "--duration-ms",
      Integer.to_string(duration_ms)
    ]

    {output, 0} = System.cmd(bench_bin, args, stderr_to_stdout: true)

    line =
      output
      |> String.split("\n", trim: true)
      |> List.last()

    decoded = :json.decode(line)
    IO.puts("BENCH_RUN_JSON=" <> line)
    decoded
  end

  defp run_nif_cell!(tcp_port, seed, cell, warmup_ms, duration_ms, rep) do
    :erlang.garbage_collect()
    bin_mem_before = :erlang.memory(:binary)
    {gc_count_before, gc_words_before, _} = :erlang.statistics(:garbage_collection)

    config = %{
      host: "127.0.0.1",
      port: tcp_port,
      region: @region,
      bucket: @bucket,
      access_key: @access_key,
      secret_key: @secret_key,
      session_token: nil,
      tls: false,
      concurrency: cell.concurrency,
      buffer_size: cell.buffer_size
    }

    {:ok, session} = Session.start_link(config: config)

    try do
      payload = if cell.op == :put, do: binary_part(seed, 0, cell.size), else: <<>>
      run_nif_window(session, seed, payload, cell, warmup_ms, {:warmup, rep})
      measured = run_nif_window(session, seed, payload, cell, duration_ms, {:measure, rep})
      bin_mem_peak = :erlang.memory(:binary)
      :erlang.garbage_collect()
      bin_mem_after = :erlang.memory(:binary)
      {gc_count_after, gc_words_after, _} = :erlang.statistics(:garbage_collection)

      record =
        Map.merge(measured, %{
          "bin_mem_before_bytes" => bin_mem_before,
          "bin_mem_peak_bytes" => bin_mem_peak,
          "bin_mem_after_bytes" => bin_mem_after,
          "gc_runs" => gc_count_after - gc_count_before,
          "gc_words_reclaimed" => gc_words_after - gc_words_before
        })

      IO.puts("BENCH_RUN_JSON=" <> encode_json(record))
      record
    after
      GenServer.stop(session, :normal, 30_000)
    end
  end

  defp run_nif_window(session, seed, payload, cell, window_ms, tag) do
    stop_at = System.monotonic_time(:millisecond) + window_ms
    cpu_before = process_cpu_seconds()
    wall_t0 = System.monotonic_time(:microsecond)

    tasks =
      Enum.map(1..cell.concurrency, fn worker_id ->
        Task.async(fn ->
          worker_loop(session, seed, payload, cell, worker_id, tag, stop_at, [])
        end)
      end)

    worker_results = Enum.map(tasks, &Task.await(&1, 120_000))
    wall_s = max((System.monotonic_time(:microsecond) - wall_t0) / 1_000_000.0, 1.0e-6)
    cpu_s = max(process_cpu_seconds() - cpu_before, 0.0)
    aggregate_nif_metrics(cell, worker_results, wall_s, cpu_s)
  end

  defp worker_loop(session, seed, payload, cell, worker_id, tag, stop_at, acc) do
    if System.monotonic_time(:millisecond) >= stop_at do
      acc
    else
      seq = length(acc) + 1
      sample = execute_nif_op(session, seed, payload, cell, worker_id, tag, seq)
      worker_loop(session, seed, payload, cell, worker_id, tag, stop_at, [sample | acc])
    end
  end

  defp execute_nif_op(session, seed, payload, %{op: :put, size: size}, worker_id, {phase, rep}, seq) do
    key = "ephemeral/nif-#{phase}-r#{rep}-w#{worker_id}-#{seq}.bin"
    opts = %{no_clobber: true, encryption: :aes256, checksum: {:sha256, @dummy_sha256}}
    t0 = System.monotonic_time(:microsecond)
    res = Session.put(session, key, payload, opts, call_timeout: 30_000)
    wall_us = System.monotonic_time(:microsecond) - t0

    case res do
      {:ok, %{end: {:answered, %{status: 200, malformed: false, encryption: :aes256}}, sent: sent}, {q_us, op_us}} ->
        {:ok, size, sent, q_us, op_us, wall_us}

      {:ok, %{end: {:not_sent, _}, sent: sent}, _} ->
        {:fail, :not_sent, sent}

      {:ok, %{end: {:unknown, _}, sent: sent}, _} ->
        {:fail, :unknown, sent}

      _ ->
        {:fail, :other, 0}
    end
    |> tap(fn _ -> _ = seed end)
  end

  defp execute_nif_op(session, _seed, _payload, %{op: :head, size: size}, _worker_id, _tag, _seq) do
    key = "seeded/#{size}.bin"
    expect = %{etag: @etag, version: @version}
    t0 = System.monotonic_time(:microsecond)
    res = Session.head(session, key, expect, call_timeout: 30_000)
    wall_us = System.monotonic_time(:microsecond) - t0

    case res do
      {:ok, %{end: {:answered, %{status: 200, malformed: false, content_length: ^size}}, sent: sent}, {q_us, op_us}} ->
        {:ok, 0, sent, q_us, op_us, wall_us}

      {:ok, %{end: {:not_sent, _}, sent: sent}, _} ->
        {:fail, :not_sent, sent}

      {:ok, %{end: {:unknown, _}, sent: sent}, _} ->
        {:fail, :unknown, sent}

      _ ->
        {:fail, :other, 0}
    end
  end

  defp execute_nif_op(session, seed, _payload, %{op: :get_range, size: size, range_len: rlen}, _w, _t, _s) do
    key = "seeded/#{size}.bin"
    expect = %{etag: @etag, version: @version}
    last = rlen - 1
    t0 = System.monotonic_time(:microsecond)
    res = Session.get(session, key, {0, last}, expect, call_timeout: 30_000)
    wall_us = System.monotonic_time(:microsecond) - t0

    case res do
      {:ok, %{end: {:answered, %{status: 206, malformed: false, body: body, body_len: ^rlen} = ans}, sent: sent},
       {q_us, op_us}}
      when is_binary(body) and byte_size(body) == rlen ->
        valid_range? =
          ans.content_range == %{first: 0, last: last, size: size} and
            :binary.first(body) == :binary.first(seed) and
            :binary.at(body, last) == :binary.at(seed, last)

        if valid_range?, do: {:ok, rlen, sent, q_us, op_us, wall_us}, else: {:fail, :other, sent}

      {:ok, %{end: {:not_sent, _}, sent: sent}, _} ->
        {:fail, :not_sent, sent}

      {:ok, %{end: {:unknown, _}, sent: sent}, _} ->
        {:fail, :unknown, sent}

      _ ->
        {:fail, :other, 0}
    end
  end

  defp aggregate_nif_metrics(cell, worker_results, wall_s, cpu_s) do
    flat = List.flatten(worker_results)
    oks = for {:ok, bytes, sent, q_us, op_us, wall_us} <- flat, do: {bytes, sent, q_us, op_us, wall_us}
    fails = for {:fail, kind, sent} <- flat, do: {kind, sent}

    ok_count = length(oks)
    payload_bytes = Enum.reduce(oks, 0, fn {b, _, _, _, _}, acc -> acc + b end)
    sent_attempts =
      Enum.reduce(oks, 0, fn {_, s, _, _, _}, acc -> acc + s end) +
        Enum.reduce(fails, 0, fn {_, s}, acc -> acc + s end)

    wall_samples = oks |> Enum.map(&elem(&1, 4)) |> Enum.sort()
    q_samples = oks |> Enum.map(&elem(&1, 2)) |> Enum.sort()
    op_samples = oks |> Enum.map(&elem(&1, 3)) |> Enum.sort()

    gib = payload_bytes / (1024.0 * 1024.0 * 1024.0)
    {rss_kib, hwm_kib} = process_memory_kib()

    %{
      "layer" => "rustler_nif",
      "op" => Atom.to_string(cell.op),
      "size_bytes" => cell.size,
      "range_bytes" => cell.range_len,
      "concurrency" => cell.concurrency,
      "buffer_size" => cell.buffer_size,
      "duration_s" => Float.round(wall_s, 6),
      "ok_ops" => ok_count,
      "failed_ops" => length(fails),
      "not_sent_ops" => Enum.count(fails, &(elem(&1, 0) == :not_sent)),
      "unknown_ops" => Enum.count(fails, &(elem(&1, 0) == :unknown)),
      "sent_attempts" => sent_attempts,
      "payload_bytes" => payload_bytes,
      "goodput_mb_s" => Float.round(payload_bytes / wall_s / 1_000_000.0, 3),
      "ops_per_s" => Float.round(ok_count / wall_s, 2),
      "cpu_seconds" => Float.round(cpu_s, 6),
      "cpu_s_per_gib" => if(gib > 0.0, do: Float.round(cpu_s / gib, 6), else: 0.0),
      "rss_kib" => rss_kib,
      "hwm_kib" => hwm_kib,
      "n" => ok_count,
      "p50_us" => percentile(wall_samples, 0.50),
      "p95_us" => percentile(wall_samples, 0.95),
      "p99_us" => percentile(wall_samples, 0.99),
      "queue_p50_us" => percentile(q_samples, 0.50),
      "queue_p99_us" => percentile(q_samples, 0.99),
      "op_p50_us" => percentile(op_samples, 0.50),
      "op_p99_us" => percentile(op_samples, 0.99)
    }
  end

  defp summarize_pairs(cell, pairs) do
    native_runs = Enum.map(pairs, &elem(&1, 0))
    nif_runs = Enum.map(pairs, &elem(&1, 1))

    native_gp = Enum.map(native_runs, &(&1["goodput_mb_s"] * 1.0))
    nif_gp = Enum.map(nif_runs, &(&1["goodput_mb_s"] * 1.0))
    native_ops = Enum.map(native_runs, &(&1["ops_per_s"] * 1.0))
    nif_ops = Enum.map(nif_runs, &(&1["ops_per_s"] * 1.0))
    native_cpu = Enum.map(native_runs, &(&1["cpu_s_per_gib"] * 1.0))
    nif_cpu = Enum.map(nif_runs, &(&1["cpu_s_per_gib"] * 1.0))

    med_native_gp = median_float(native_gp)
    med_nif_gp = median_float(nif_gp)
    med_native_cpu = median_float(native_cpu)
    med_nif_cpu = median_float(nif_cpu)

    gp_ratio =
      if med_native_gp > 0.0 do
        Float.round(med_nif_gp / med_native_gp, 4)
      else
        Float.round(median_float(nif_ops) / max(median_float(native_ops), 1.0e-6), 4)
      end

    cpu_ratio =
      if med_native_cpu > 0.0 do
        Float.round(med_nif_cpu / med_native_cpu, 4)
      else
        0.0
      end

    %{
      op: Atom.to_string(cell.op),
      size_bytes: cell.size,
      range_bytes: cell.range_len,
      concurrency: cell.concurrency,
      buffer_size: cell.buffer_size,
      runs: length(pairs),
      native_median_mb_s: Float.round(med_native_gp, 3),
      native_min_mb_s: Float.round(Enum.min(native_gp), 3),
      native_max_mb_s: Float.round(Enum.max(native_gp), 3),
      nif_median_mb_s: Float.round(med_nif_gp, 3),
      nif_min_mb_s: Float.round(Enum.min(nif_gp), 3),
      nif_max_mb_s: Float.round(Enum.max(nif_gp), 3),
      native_median_ops_per_s: Float.round(median_float(native_ops), 2),
      nif_median_ops_per_s: Float.round(median_float(nif_ops), 2),
      goodput_ratio_nif_vs_native: gp_ratio,
      native_median_cpu_s_per_gib: Float.round(med_native_cpu, 6),
      nif_median_cpu_s_per_gib: Float.round(med_nif_cpu, 6),
      cpu_s_per_gib_ratio: cpu_ratio,
      native_median_p50_us: round(median_float(Enum.map(native_runs, &(&1["p50_us"] * 1.0)))),
      native_median_p99_us: round(median_float(Enum.map(native_runs, &(&1["p99_us"] * 1.0)))),
      nif_median_p50_us: round(median_float(Enum.map(nif_runs, &(&1["p50_us"] * 1.0)))),
      nif_median_p99_us: round(median_float(Enum.map(nif_runs, &(&1["p99_us"] * 1.0)))),
      nif_median_queue_p50_us: round(median_float(Enum.map(nif_runs, &(&1["queue_p50_us"] * 1.0)))),
      nif_median_op_p50_us: round(median_float(Enum.map(nif_runs, &(&1["op_p50_us"] * 1.0)))),
      nif_peak_bin_mem_bytes: Enum.max(Enum.map(nif_runs, & &1["bin_mem_peak_bytes"])),
      nif_after_gc_bin_mem_bytes: List.last(nif_runs)["bin_mem_after_bytes"],
      nif_rss_kib: Enum.max(Enum.map(nif_runs, & &1["rss_kib"])),
      native_rss_kib: Enum.max(Enum.map(native_runs, & &1["rss_kib"]))
    }
  end

  defp start_peer!(bench_bin) do
    port_handle =
      Port.open({:spawn_executable, bench_bin}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1024},
        {:args, ["peer", "--port", "0"]}
      ])

    receive do
      {^port_handle, {:data, {:eol, "PORT=" <> port_str}}} ->
        {port_handle, String.to_integer(String.trim(port_str))}
    after
      10_000 -> flunk("timed out waiting for longshore_bench peer port")
    end
  end

  defp safe_close_port(port_handle) do
    if Port.info(port_handle) != nil do
      Port.close(port_handle)
    end
  catch
    _, _ -> :ok
  end

  defp resolve_bench_binary! do
    candidates = [
      System.get_env("LONGSHORE_BENCH_BIN"),
      Path.expand("../native/longshore_nif/longshore_bench", __DIR__),
      Path.join(File.cwd!(), "elixir/serviceradar_object_storage/native/longshore_nif/longshore_bench")
    ]

    Enum.find(candidates, &(is_binary(&1) and File.exists?(&1))) ||
      raise "longshore_bench binary not found in runfiles"
  end

  defp build_seed_binary(len) when rem(len, 65_536) == 0 do
    block =
      for idx <- 0..65_535, into: <<>> do
        word = idx * 2_654_435_761 &&& 0xFFFFFFFF
        byte = bxor(word >>> 16 &&& 0xFF, 0x5A)
        <<byte>>
      end

    :binary.copy(block, div(len, 65_536))
  end

  defp host_environment do
    kernel =
      case File.read("/proc/sys/kernel/osrelease") do
        {:ok, s} -> String.trim(s)
        _ -> "unknown"
      end

    memlock =
      case File.read("/proc/self/limits") do
        {:ok, text} ->
          text
          |> String.split("\n")
          |> Enum.find_value("unknown", fn line ->
            if String.starts_with?(line, "Max locked memory") do
              cols = String.split(line)
              "soft=#{Enum.at(cols, 3)} hard=#{Enum.at(cols, 4)}"
            end
          end)

        _ ->
          "unknown"
      end

    %{
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      erts_version: List.to_string(:erlang.system_info(:version)),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
      kernel: kernel,
      memlock: memlock
    }
  end

  defp process_cpu_seconds do
    case File.read("/proc/self/stat") do
      {:ok, stat} ->
        [_, rest] = String.split(stat, ")", parts: 2)
        fields = String.split(rest)
        utime = fields |> Enum.at(11, "0") |> String.to_integer()
        stime = fields |> Enum.at(12, "0") |> String.to_integer()
        (utime + stime) / 100.0

      _ ->
        0.0
    end
  end

  defp process_memory_kib do
    case File.read("/proc/self/status") do
      {:ok, text} ->
        {parse_status_kib(text, "VmRSS:"), parse_status_kib(text, "VmHWM:")}

      _ ->
        {0, 0}
    end
  end

  defp parse_status_kib(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      if String.starts_with?(line, prefix) do
        line |> String.replace_prefix(prefix, "") |> String.split() |> List.first("0") |> String.to_integer()
      end
    end)
  end

  defp percentile([], _q), do: 0

  defp percentile(sorted, q) do
    idx = round((length(sorted) - 1) * q)
    Enum.at(sorted, min(max(idx, 0), length(sorted) - 1))
  end

  defp median_float([]), do: 0.0

  defp median_float(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      raw -> String.to_integer(raw)
    end
  end

  defp encode_json(term), do: IO.iodata_to_binary(:json.encode(term))
end
