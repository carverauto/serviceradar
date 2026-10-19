defmodule ServiceRadarWebNG.Topology.Scale.Client do
  @moduledoc false
  use GenServer

  alias ServiceRadarWebNG.Topology.Scale.Fixture
  alias ServiceRadarWebNG.Topology.Scale.Revisions

  @topic "topology:tiles"
  @retry_reasons ~w(membership_not_ready index_not_ready index_unavailable prefix_source_unavailable source_changed query_busy query_timeout query_unavailable)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def phase(pid, phase), do: GenServer.call(pid, {:phase, phase})
  def report(pid), do: GenServer.call(pid, :report)

  def http(session, method, path, body \\ "") do
    {:ok, conn} = :gun.open(~c"127.0.0.1", session.port, %{protocols: [:http], retry: 0})

    try do
      {:ok, :http} = :gun.await_up(conn, 5_000)
      headers = [{"cookie", session.cookie}, {"x-csrf-token", session.csrf}, {"content-type", "application/json"}]
      ref = :gun.request(conn, method, path, headers, body)

      case :gun.await(conn, ref, 10_000) do
        {:response, :fin, status, response_headers} ->
          {status, response_headers, ""}

        {:response, :nofin, status, response_headers} ->
          {:ok, bytes} = :gun.await_body(conn, ref, 10_000)
          {status, response_headers, bytes}

        other ->
          raise "HTTP acceptance request failed: #{inspect(other)}"
      end
    after
      :gun.close(conn)
    end
  end

  def receipts(session) do
    for y <- 0..7, x <- 0..7 do
      {200, headers, bytes} = http(session, "GET", "/topology/tiles/#{session.version}/3/#{x}/#{y}")
      true = byte_size(bytes) > 0 and byte_size(bytes) <= 262_144
      {"etag", etag} = List.keyfind(headers, "etag", 0)
      [version, revision] = etag |> String.trim("\"") |> String.split(":", parts: 2)
      true = version == session.version and byte_size(revision) == 64
      %{"z" => 3, "x" => x, "y" => y, "revision" => revision}
    end
  end

  # Holds `count` concurrent sockets open until each upgrade resolves, so it
  # exercises the same session, CSRF, token and RBAC boundary as the viewers
  # and fails if established sockets keep any database connection checked out.
  def upgrades(session, count) do
    sockets = for _ <- 1..count, do: open_socket(session)

    try do
      Enum.map(sockets, fn {conn, stream} ->
        receive do
          {:gun_upgrade, ^conn, ^stream, ["websocket"], _headers} -> :upgraded
          {:gun_response, ^conn, ^stream, _fin, status, _headers} -> {:refused, status}
          {:gun_error, ^conn, ^stream, reason} -> {:error, reason}
        after
          15_000 -> :timeout
        end
      end)
    after
      Enum.each(sockets, fn {conn, _} -> :gun.close(conn) end)
    end
  end

  defp open_socket(session) do
    {:ok, conn} = :gun.open(~c"127.0.0.1", session.port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)
    path = "/socket/websocket?vsn=2.0.0&_csrf_token=" <> URI.encode_www_form(session.csrf)
    {conn, :gun.ws_upgrade(conn, path, [{"cookie", session.cookie}], %{compress: false})}
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    session = Keyword.fetch!(opts, :session)
    {conn, stream} = open_socket(session)

    state = %{
      conn: conn,
      stream: stream,
      session: session,
      tiles: Keyword.fetch!(opts, :tiles),
      slow: Keyword.get(opts, :slow, false),
      revisions: Keyword.fetch!(opts, :revisions),
      blank_since: now(),
      started: nil,
      awaiting: nil,
      ref: 1,
      binding: nil,
      retry_attempt: 0,
      retry_timer: nil,
      phase: :warmup,
      phase_since: now(),
      stats: %{
        frames: 0,
        resets: 0,
        requests: 0,
        bytes: 0,
        max_frame_bytes: 0,
        errors: %{},
        latency_ms: %{},
        latest_total: nil,
        last_frame_at: nil,
        last_revision: nil,
        max_normal_gap_ms: 0,
        slow_resets: 0,
        max_slow_reset_ms: 0,
        retries: 0
      }
    }

    Process.send_after(self(), :progress, 1_000)
    {:ok, state}
  end

  def handle_info({:gun_upgrade, conn, stream, ["websocket"], _headers}, %{conn: conn, stream: stream} = state) do
    send_event(state, "phx_join", %{}, "1")
    Process.send_after(self(), :heartbeat, 20_000)
    {:noreply, state}
  end

  def handle_info({:gun_ws, conn, stream, {:text, bytes}}, %{conn: conn, stream: stream} = state) do
    case Jason.decode!(bytes) do
      [_, "1", @topic, "phx_reply", %{"status" => "ok"}] ->
        send(self(), :watch)
        {:noreply, state}

      [_, _, @topic, "phx_reply", %{"status" => "error", "response" => %{"reason" => reason}}] ->
        state = error(%{state | started: nil}, reason)
        {:noreply, if(reason in @retry_reasons, do: retry(state), else: state)}

      [_, _, @topic, "topology_error", %{"reason" => reason}] ->
        {:noreply, error(state, reason)}

      [_, _, @topic, "phx_close", _] ->
        {:noreply, error(state, "channel_closed")}

      [_, _, @topic, "phx_reply", %{"status" => "ok", "response" => %{"view_digest" => _} = binding}] ->
        {:noreply, %{state | binding: binding}}

      [_, _, _, "phx_reply", %{"status" => "ok"}] ->
        {:noreply, state}

      [_, _, _, "topology_invalidated", _] ->
        {:noreply, state}

      message ->
        {:stop, {:unexpected_text, message}, state}
    end
  end

  def handle_info({:gun_ws, conn, stream, {:binary, bytes}}, %{conn: conn, stream: stream} = state) do
    decoded = decode(bytes, state.tiles)

    case decoded.kind do
      :reset ->
        elapsed = if state.awaiting, do: now() - state.stats.last_frame_at, else: 0
        slow_reset = state.slow and elapsed >= 15_000
        true = not slow_reset or elapsed <= 21_000

        stats = %{
          state.stats
          | resets: state.stats.resets + 1,
            slow_resets: state.stats.slow_resets + if(slow_reset, do: 1, else: 0),
            max_slow_reset_ms: max(state.stats.max_slow_reset_ms, if(slow_reset, do: elapsed, else: 0))
        }

        state = %{state | started: nil, awaiting: nil, blank_since: state.blank_since || now(), stats: stats}
        {:noreply, retry(state)}

      :baseline ->
        true = not is_nil(state.binding)
        true = Enum.all?(decoded.binding, fn {key, value} -> state.binding[key] == value end)
        stats = state.stats
        now = now()

        histogram =
          if state.started do
            ms = System.monotonic_time(:millisecond) - state.started
            Map.update(stats.latency_ms, min(ms, 60_000), 1, &(&1 + 1))
          else
            stats.latency_ms
          end

        stats = %{
          stats
          | frames: stats.frames + 1,
            bytes: stats.bytes + byte_size(bytes),
            max_frame_bytes: max(stats.max_frame_bytes, decoded.bytes),
            latency_ms: histogram,
            latest_total: decoded.total,
            last_frame_at: now,
            last_revision: decoded.revision
        }

        if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
        Process.send_after(self(), {:ack, decoded.sequence, decoded.digest}, if(state.slow, do: 25_000, else: 0))
        state = %{state | retry_attempt: 0, retry_timer: nil}

        {:noreply, %{state | started: nil, awaiting: decoded.sequence, blank_since: nil, stats: stats}}
    end
  end

  def handle_info(:watch, %{started: nil, awaiting: nil} = state) do
    ref = state.ref + 1

    params = %{
      "protocol" => 1,
      "layout_version" => state.session.version,
      "query" => Fixture.query(),
      "tiles" => state.tiles
    }

    send_event(state, "membership:watch", params, Integer.to_string(ref))
    Process.send_after(self(), {:watch_timeout, ref}, 10_000)

    {:noreply,
     %{
       state
       | ref: ref,
         retry_timer: nil,
         started: System.monotonic_time(:millisecond),
         stats: %{state.stats | requests: state.stats.requests + 1}
     }}
  end

  def handle_info(:watch, state), do: {:noreply, state}

  def handle_info({:watch_timeout, ref}, %{ref: ref, started: started} = state) when not is_nil(started) do
    {:noreply, retry(error(%{state | started: nil}, "client_deadline"))}
  end

  def handle_info({:watch_timeout, _}, state), do: {:noreply, state}

  def handle_info({:ack, sequence, digest}, %{awaiting: sequence} = state) do
    send_event(state, "membership:ack", %{"sequence" => Integer.to_string(sequence), "view_digest" => digest}, "ack")
    {:noreply, %{state | awaiting: nil}}
  end

  def handle_info({:ack, _, _}, state), do: {:noreply, state}

  # A churning normal viewer may neither show no membership nor hold a revision
  # its replica has superseded for more than 30 seconds. It stops with its own
  # bounded report so the driver can fail at once with the cause.
  def handle_info(:progress, state) do
    Process.send_after(self(), :progress, 1_000)

    if not state.slow and state.phase == :churn do
      gap =
        case stale_since(state) do
          nil -> 0
          since -> now() - max(since, state.phase_since)
        end

      state = update_in(state.stats.max_normal_gap_ms, &max(&1, gap))

      if gap > 30_000,
        do: {:stop, {:no_progress, progress_report(state, gap)}, state},
        else: {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!([nil, "heartbeat", "phoenix", "heartbeat", %{}])})
    Process.send_after(self(), :heartbeat, 20_000)
    {:noreply, state}
  end

  def handle_info({:gun_ws, _, _, {:close, _code, _reason}}, state), do: {:noreply, error(state, "socket_closed")}
  def handle_info({:gun_ws, _, _, :close}, state), do: {:noreply, error(state, "socket_closed")}
  def handle_info({:gun_down, _, _, reason, _}, state), do: {:noreply, error(state, "gun_down:#{inspect(reason)}")}
  def handle_info({:EXIT, _, :normal}, state), do: {:noreply, state}

  def handle_info({:gun_response, conn, stream, _fin, status, _headers}, %{conn: conn, stream: stream} = state),
    do: {:stop, {:upgrade_refused, status}, state}

  def handle_info(message, state), do: {:stop, {:unexpected_transport, message}, state}

  def handle_call({:phase, phase}, _from, state) when phase in [:churn, :steady, :recovery] do
    if phase == state.phase, do: {:reply, :ok, state}, else: {:reply, :ok, %{state | phase: phase, phase_since: now()}}
  end

  def handle_call(:report, _from, state), do: {:reply, state.stats, state}
  def terminate(_reason, state), do: :gun.close(state.conn)

  # Crash reports must not print the session cookie or CSRF token.
  def format_status(status), do: Map.update(status, :state, nil, &Map.put(&1, :session, :redacted))

  # Emulate the production WorldMapRenderer reset/transient backoff. Only an
  # accepted full frame resets it; a successful binding alone proves no progress.
  # Healthy watches stay subscribed to the real server tick.
  defp retry(state) do
    delay = min(10_000, 1_000 * Integer.pow(2, min(state.retry_attempt, 4)))
    state = %{state | retry_attempt: state.retry_attempt + 1, stats: %{state.stats | retries: state.stats.retries + 1}}
    schedule(state, delay)
  end

  defp schedule(state, delay) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: Process.send_after(self(), :watch, delay)}
  end

  defp stale_since(%{blank_since: since}) when not is_nil(since), do: since

  defp stale_since(%{revisions: table, stats: %{last_revision: {epoch, revision}}}),
    do: Revisions.behind_since(table, epoch, String.to_integer(revision))

  defp progress_report(state, gap) do
    %{
      gap_ms: gap,
      blank: not is_nil(state.blank_since),
      held_revision: state.stats.last_revision && Tuple.to_list(state.stats.last_revision),
      stats: Map.drop(state.stats, [:latency_ms, :last_frame_at, :last_revision])
    }
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp error(state, reason), do: update_in(state.stats.errors, &Map.update(&1, reason, 1, fn count -> count + 1 end))

  defp send_event(state, event, payload, ref),
    do: :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(["1", ref, @topic, event, payload])})

  # Independent protocol consumer: validates the actual Phoenix envelope and all
  # rows, not a re-encoding of the producer's response. These views cover the
  # complete synthetic world, so their disjoint row counts must sum to total.
  def decode(<<0, join_size, topic_size, event_size, rest::binary>>, receipts) do
    <<_join::binary-size(join_size), topic::binary-size(topic_size), event::binary-size(event_size), frame::binary>> =
      rest

    true = topic == @topic and event == "membership:frame"
    <<"SRMO", 1, kind, 0::little-16, size::little-32, sequence::little-64, total::little-32, tail::binary>> = frame
    true = size == byte_size(frame) and size <= 262_144

    {fields, tail} =
      Enum.map_reduce(1..7, tail, fn _, <<size::little-16, rest::binary>> ->
        true = size in 1..128
        <<value::binary-size(size), rest::binary>> = rest
        {value, rest}
      end)

    digest = Enum.at(fields, 4)
    tail = take_prefix_freshness(tail)

    case kind do
      1 ->
        <<>> = tail
        %{kind: :reset, sequence: sequence, digest: digest}

      0 ->
        <<count, tail::binary>> = tail
        true = count in 1..64 and count == length(receipts)
        expected = Map.new(receipts, &{{&1["z"], &1["x"], &1["y"]}, &1["revision"]})

        {sum, <<>>, remaining} =
          Enum.reduce(1..count, {0, tail, expected}, fn _, {sum, bytes, expected} ->
            <<z, x::little-32, y::little-32, length::little-16, revision::binary-size(length), rows::little-16,
              rest::binary>> = bytes

            true = rows <= 128 and expected[{z, x, y}] == revision

            <<mask::binary-size(rows), causal::binary-size(rows), availability::binary-size(rows),
              counts::binary-size(rows * 4), rest::binary>> = rest

            values = for <<n::little-32 <- counts>>, do: n
            true = :binary.bin_to_list(mask) == Enum.map(values, &if(&1 > 0, do: 1, else: 0))
            true = causal == :binary.copy(<<3>>, rows)
            true = :binary.bin_to_list(availability) == Enum.map(values, &if(&1 > 0, do: 1, else: 2))
            {sum + Enum.sum(values), rest, Map.delete(expected, {z, x, y})}
          end)

        true = remaining == %{} and sum == total

        binding =
          Map.new(
            Enum.zip(
              ~w(dictionary_epoch query_digest authority_fingerprint view_digest),
              Enum.map([0, 2, 3, 4], &Enum.at(fields, &1))
            )
          )

        %{
          kind: :baseline,
          sequence: sequence,
          digest: digest,
          total: total,
          bytes: size,
          revision: {Enum.at(fields, 1), Enum.at(fields, 6)},
          binding: binding
        }
    end
  end

  defp take_prefix_freshness(<<count, rest::binary>>) when count <= 32, do: skip_prefix_sources(rest, count, "")

  defp skip_prefix_sources(rest, 0, _previous), do: rest

  defp skip_prefix_sources(<<length::little-16, rest::binary>>, count, previous)
       when count in 1..32 and length in 1..128 do
    <<source::binary-size(length), _version::little-64, rest::binary>> = rest
    true = source > previous and String.valid?(source) and :binary.match(source, <<0>>) == :nomatch
    skip_prefix_sources(rest, count - 1, source)
  end
end
