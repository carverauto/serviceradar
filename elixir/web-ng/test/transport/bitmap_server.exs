defmodule ServiceRadarWebNG.BitmapTransport.Server do
  @moduledoc false
  alias ServiceRadarWebNG.BitmapTransport.Channel
  alias ServiceRadarWebNG.BitmapTransport.Endpoint
  alias ServiceRadarWebNG.BitmapTransport.PubSub

  def start(frames) do
    Logger.configure(level: :warning)
    :persistent_term.put({Channel, :frames}, frames)

    :ok =
      :telemetry.attach(
        "bitmap-transport-stop",
        [:bandit, :websocket, :stop],
        &__MODULE__.websocket_stopped/4,
        nil
      )

    Application.put_env(:phoenix, :json_library, Jason)

    Application.put_env(:serviceradar_web_ng, Endpoint,
      server: false,
      check_origin: false,
      secret_key_base: String.duplicate("synthetic-transport-key", 4),
      pubsub_server: PubSub
    )

    listener = {Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__]]}},
          {Phoenix.PubSub, name: PubSub},
          Endpoint,
          Supervisor.child_spec(listener, id: :listener)
        ],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)
    {:listener, listener, _, _} = Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == :listener))
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    %{
      port: port,
      schedulers: :erlang.system_info(:schedulers_online),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      phoenix: List.to_string(Application.spec(:phoenix, :vsn)),
      bandit: List.to_string(Application.spec(:bandit, :vsn))
    }
  end

  def websocket_stopped(_event, measurements, metadata, _config) do
    entry = {metadata.telemetry_span_context, measurements, Map.get(metadata, :error)}
    Agent.update(__MODULE__, &[entry | &1])
  end

  def resources do
    {cpu_ms, _} = :erlang.statistics(:runtime)
    status = File.read!("/proc/self/status")
    [_, rss_kib] = Regex.run(~r/^VmRSS:\s+(\d+) kB$/m, status)
    [_, peak_kib] = Regex.run(~r/^VmHWM:\s+(\d+) kB$/m, status)
    [_, stat_fields] = String.split(File.read!("/proc/self/stat"), ") ", parts: 2)
    fields = String.split(stat_fields)
    user_ticks = fields |> Enum.at(11) |> String.to_integer()
    system_ticks = fields |> Enum.at(12) |> String.to_integer()
    word_bits = :erlang.system_info(:wordsize) * 8
    # Linux AT_CLKTCK provides the /proc CPU tick frequency without assuming HZ
    # or invoking an undeclared system executable. RSS includes native zlib.
    auxv =
      for <<key::native-unsigned-size(word_bits),
            value::native-unsigned-size(word_bits) <- File.read!("/proc/self/auxv")>>, into: %{}, do: {key, value}

    ticks_per_second = Map.fetch!(auxv, 17)

    %{
      cpu_ms: cpu_ms,
      os_user_ticks: user_ticks,
      os_system_ticks: system_ticks,
      os_ticks_per_second: ticks_per_second,
      os_cpu_ms: (user_ticks + system_ticks) * 1000 / ticks_per_second,
      rss_bytes: String.to_integer(rss_kib) * 1024,
      peak_rss_bytes: String.to_integer(peak_kib) * 1024,
      beam_bytes: :erlang.memory(:total)
    }
  end

  def closed(expected, deadline) do
    entries = Agent.get(__MODULE__, & &1)

    cond do
      length(entries) == expected ->
        Enum.reduce(entries, %{connections: expected, frames: 0, bytes: 0, errors: 0}, fn {_, metrics, error}, totals ->
          %{
            totals
            | frames: totals.frames + Map.get(metrics, :send_binary_frame_count, 0),
              bytes: totals.bytes + Map.get(metrics, :send_binary_frame_bytes, 0),
              errors: totals.errors + if(is_nil(error), do: 0, else: 1)
          }
        end)

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:unclosed_connections, length(entries), expected}}

      true ->
        receive do
        after
          10 -> closed(expected, deadline)
        end
    end
  end

  def closed(expected), do: closed(expected, System.monotonic_time(:millisecond) + 10_000)
end
