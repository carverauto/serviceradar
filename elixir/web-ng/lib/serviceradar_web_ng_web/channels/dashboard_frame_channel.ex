defmodule ServiceRadarWebNGWeb.DashboardFrameChannel do
  @moduledoc false
  use Phoenix.Channel

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.FrameRunner
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Endpoint

  require Logger

  @default_refresh_ms 15_000
  @min_refresh_ms 1_000
  @max_refresh_ms 60_000
  @stream_salt "dashboard-frame-stream-v1"
  @stream_token_max_age 3_600
  @binary_magic "DFB1"

  @impl true
  def join("dashboards:" <> route_slug, %{"token" => token} = payload, socket) when is_binary(route_slug) do
    with true <- Map.has_key?(socket.assigns, :current_user),
         {:ok, stream} <- verify_stream_token(token),
         :ok <- verify_route_slug(route_slug, stream),
         :ok <- verify_token_user(stream, socket),
         {:ok, scope} <- RBAC.authorize_current(socket.assigns.current_scope, []),
         {:ok, %DashboardInstance{}} <-
           Dashboards.get_enabled_instance_by_slug(route_slug, scope: scope) do
      socket =
        socket
        |> assign(:current_scope, scope)
        |> assign(:route_slug, route_slug)
        |> assign(:all_data_frames, normalize_data_frames(stream["data_frames"] || stream[:data_frames]))
        |> assign(:initial_data_frames, initial_data_frames(stream))
        |> assign(:deferred_data_frames, deferred_data_frames(stream))
        |> assign(:refresh_data_frames, refresh_data_frames(stream))
        |> assign(:frame_cursors, %{})
        |> assign(:last_frames, [])
        |> assign(:initial_frame_sent, false)
        |> assign(:deferred_frame_sent, false)
        |> assign(:refresh_ms, refresh_ms(payload["refresh_interval_ms"]))
        |> assign(:last_frame_hash, nil)
        |> assign(:refresh_task_ref, nil)
        |> assign(:refresh_task_kind, nil)

      send(self(), :dashboard_frame_tick)
      {:ok, %{"refresh_interval_ms" => socket.assigns.refresh_ms}, socket}
    else
      false -> {:error, %{reason: "unauthorized"}}
      {:error, :unauthorized} -> {:error, %{reason: "unauthorized"}}
      {:error, :permission_revoked} -> {:error, %{reason: "unauthorized"}}
      {:error, :invalid_route} -> {:error, %{reason: "invalid_stream"}}
      {:error, :not_found} -> {:error, %{reason: "dashboard_unavailable"}}
      {:error, reason} -> {:error, %{reason: format_error(reason)}}
    end
  end

  def join("dashboards:" <> _route_slug, _payload, _socket), do: {:error, %{reason: "missing_stream_token"}}

  @impl true
  def handle_info(:dashboard_frame_tick, socket) do
    {kind, data_frames} = tick_data_frames(socket)
    socket = start_frame_refresh(socket, data_frames, kind)

    Process.send_after(self(), :dashboard_frame_tick, socket.assigns.refresh_ms)
    {:noreply, socket}
  end

  def handle_info({:dashboard_frame_result, ref, {:ok, updates}}, %{assigns: %{refresh_task_ref: ref}} = socket) do
    kind = socket.assigns.refresh_task_kind

    socket =
      socket
      |> assign(:refresh_task_ref, nil)
      |> assign(:refresh_task_kind, nil)
      |> mark_frame_batch_sent(kind)
      |> push_frame_updates(updates)
      |> maybe_start_deferred_frame_refresh(kind)

    {:noreply, socket}
  end

  def handle_info({:dashboard_frame_result, ref, {:error, reason}}, %{assigns: %{refresh_task_ref: ref}} = socket) do
    kind = socket.assigns.refresh_task_kind

    Logger.error("dashboard frame stream failed route_slug=#{socket.assigns[:route_slug]} error=#{inspect(reason)}")
    push(socket, "frames:error", %{"reason" => "frame_stream_unavailable"})

    socket =
      socket
      |> assign(:refresh_task_ref, nil)
      |> assign(:refresh_task_kind, nil)
      |> mark_frame_batch_sent(kind)
      |> maybe_start_deferred_frame_refresh(kind)

    {:noreply, socket}
  end

  def handle_info({:dashboard_frame_result, _ref, _result}, socket), do: {:noreply, socket}

  @impl true
  def handle_in("frames:refresh", _payload, socket) do
    socket =
      socket
      |> assign(:last_frame_hash, nil)
      |> assign(:frame_cursors, %{})
      |> assign(:deferred_frame_sent, false)
      |> start_frame_refresh(socket.assigns.initial_data_frames, :initial)

    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("frames:page", payload, socket) do
    frame_id = payload |> Map.get("frame_id") |> to_string() |> String.trim()
    cursor = payload |> Map.get("cursor") |> to_string() |> String.trim()

    if frame_id == "" or cursor == "" do
      {:reply, {:error, %{reason: "frame_id and cursor are required"}}, socket}
    else
      case find_data_frame(socket, frame_id) do
        nil ->
          {:reply, {:error, %{reason: "unknown_frame"}}, socket}

        frame ->
          socket =
            socket
            |> assign(:frame_cursors, Map.put(socket.assigns.frame_cursors, frame_id, cursor))
            |> start_frame_refresh([Map.put(frame, "cursor", cursor)], :page)

          {:reply, {:ok, %{}}, socket}
      end
    end
  end

  defp start_frame_refresh(%{assigns: %{refresh_task_ref: ref}} = socket, _data_frames, _kind) when not is_nil(ref),
    do: socket

  defp start_frame_refresh(socket, data_frames, kind) do
    ref = make_ref()
    parent = self()
    scope = socket.assigns.current_scope
    data_frames = apply_frame_cursors(data_frames, socket.assigns[:frame_cursors] || %{})

    case Task.start(fn -> send(parent, {:dashboard_frame_result, ref, run_data_frames(data_frames, scope)}) end) do
      {:ok, _pid} ->
        socket
        |> assign(:refresh_task_ref, ref)
        |> assign(:refresh_task_kind, kind)

      {:error, reason} ->
        Logger.error(
          "dashboard frame stream task failed route_slug=#{socket.assigns[:route_slug]} error=#{inspect(reason)}"
        )

        push(socket, "frames:error", %{"reason" => "frame_stream_unavailable"})
        socket
    end
  end

  defp run_data_frames(data_frames, scope) do
    {:ok, FrameRunner.run(data_frames, scope)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp push_frame_updates(socket, updates) do
    frames =
      socket.assigns
      |> Map.get(:last_frames, [])
      |> merge_frames(updates)

    hash = :erlang.phash2(frames)

    if socket.assigns[:last_frame_hash] == hash do
      socket
    else
      {metadata_frames, binary_frames} = prepare_frame_transport(frames)

      push(socket, "frames:replace", %{
        "frames" => metadata_frames,
        "pending_binary_frame_ids" => Enum.map(binary_frames, & &1["id"]),
        "data_provider" => %{
          "version" => "dashboard-data-v1",
          "frames" => Enum.map(frames, &frame_summary/1)
        },
        "generated_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      Enum.each(binary_frames, fn frame ->
        push(socket, "frame:binary", {:binary, encode_binary_frame(frame)})
      end)

      socket
      |> assign(:last_frames, frames)
      |> assign(:last_frame_hash, hash)
    end
  rescue
    error ->
      Logger.error("dashboard frame stream failed route_slug=#{socket.assigns[:route_slug]} error=#{inspect(error)}")
      push(socket, "frames:error", %{"reason" => "frame_stream_unavailable"})
      socket
  end

  def stream_token(route_slug, data_frames, user_id, active_frame_ids \\ [])
      when is_binary(route_slug) and is_list(data_frames) and not is_nil(user_id) do
    Phoenix.Token.sign(Endpoint, @stream_salt, %{
      "route_slug" => route_slug,
      "user_id" => to_string(user_id),
      "data_frames" => data_frames,
      "active_frame_ids" => normalize_frame_ids(active_frame_ids)
    })
  end

  defp verify_stream_token(token) when is_binary(token) do
    Phoenix.Token.verify(Endpoint, @stream_salt, token, max_age: @stream_token_max_age)
  end

  defp verify_stream_token(_token), do: {:error, :invalid_stream}

  defp verify_route_slug(route_slug, %{"route_slug" => route_slug}), do: :ok
  defp verify_route_slug(route_slug, %{route_slug: route_slug}), do: :ok
  defp verify_route_slug(_route_slug, _stream), do: {:error, :invalid_route}

  defp verify_token_user(stream, socket) do
    token_user_id = stream["user_id"] || stream[:user_id]
    socket_user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    if token_user_id not in [nil, ""] and socket_user_id not in [nil, ""] and
         to_string(token_user_id) == to_string(socket_user_id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp normalize_data_frames(data_frames) when is_list(data_frames), do: data_frames
  defp normalize_data_frames(_data_frames), do: []

  defp tick_data_frames(%{assigns: %{initial_frame_sent: false, initial_data_frames: data_frames}}),
    do: {:initial, data_frames}

  defp tick_data_frames(%{assigns: %{deferred_frame_sent: false, deferred_data_frames: [_ | _] = data_frames}}),
    do: {:deferred, data_frames}

  defp tick_data_frames(%{assigns: %{refresh_data_frames: data_frames}}), do: {:refresh, data_frames}

  defp initial_data_frames(stream) do
    data_frames = normalize_data_frames(stream["data_frames"] || stream[:data_frames])
    required_frames = Enum.filter(data_frames, &required_frame?/1)

    case required_frames do
      [] -> active_optional_data_frames(data_frames, stream)
      frames -> frames
    end
  end

  defp deferred_data_frames(stream) do
    data_frames = normalize_data_frames(stream["data_frames"] || stream[:data_frames])
    active_frame_ids = MapSet.new(normalize_frame_ids(stream["active_frame_ids"] || stream[:active_frame_ids]))
    initial_frame_ids = stream |> initial_data_frames() |> MapSet.new(&frame_id/1)

    Enum.filter(data_frames, fn frame ->
      id = frame_id(frame)

      not required_frame?(frame) and MapSet.member?(active_frame_ids, id) and
        not MapSet.member?(initial_frame_ids, id)
    end)
  end

  defp refresh_data_frames(stream) do
    stream
    |> then(&normalize_data_frames(&1["data_frames"] || &1[:data_frames]))
    |> Enum.filter(&required_frame?/1)
  end

  defp active_optional_data_frames(data_frames, stream) do
    active_frame_ids =
      MapSet.new(normalize_frame_ids(stream["active_frame_ids"] || stream[:active_frame_ids]))

    Enum.filter(data_frames, &MapSet.member?(active_frame_ids, frame_id(&1)))
  end

  defp mark_frame_batch_sent(socket, :initial), do: assign(socket, :initial_frame_sent, true)
  defp mark_frame_batch_sent(socket, :deferred), do: assign(socket, :deferred_frame_sent, true)
  defp mark_frame_batch_sent(socket, _kind), do: socket

  defp maybe_start_deferred_frame_refresh(
         %{assigns: %{deferred_frame_sent: false, deferred_data_frames: [_ | _] = data_frames}} = socket,
         :initial
       ) do
    start_frame_refresh(socket, data_frames, :deferred)
  end

  defp maybe_start_deferred_frame_refresh(socket, _kind), do: socket

  defp required_frame?(frame) when is_map(frame) do
    case frame_value(frame, "required", :required) do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp required_frame?(_frame), do: true

  defp frame_id(%{"id" => id}) when is_binary(id), do: id
  defp frame_id(%{id: id}) when is_binary(id), do: id
  defp frame_id(_frame), do: ""

  defp find_data_frame(socket, frame_id) do
    Enum.find(socket.assigns[:all_data_frames] || [], fn frame -> frame_id(frame) == frame_id end)
  end

  defp apply_frame_cursors(data_frames, cursors) when is_map(cursors) and map_size(cursors) > 0 do
    Enum.map(data_frames, fn frame ->
      case Map.get(cursors, frame_id(frame)) do
        cursor when is_binary(cursor) and cursor != "" -> Map.put(frame, "cursor", cursor)
        _ -> frame
      end
    end)
  end

  defp apply_frame_cursors(data_frames, _cursors), do: data_frames

  defp frame_value(frame, string_key, atom_key) when is_map(frame) do
    cond do
      Map.has_key?(frame, string_key) -> Map.get(frame, string_key)
      Map.has_key?(frame, atom_key) -> Map.get(frame, atom_key)
      true -> nil
    end
  end

  defp normalize_frame_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_frame_ids(_ids), do: []

  defp merge_frames([], updates), do: updates

  defp merge_frames(previous, updates) do
    update_by_id = Map.new(updates, fn frame -> {frame["id"], frame} end)
    previous_ids = MapSet.new(Enum.map(previous, & &1["id"]))

    replaced =
      Enum.map(previous, fn frame ->
        update_by_id
        |> Map.get(frame["id"], frame)
        |> preserve_previous_results_on_error(frame)
      end)

    appended =
      Enum.reject(updates, fn frame ->
        MapSet.member?(previous_ids, frame["id"])
      end)

    replaced ++ appended
  end

  defp preserve_previous_results_on_error(%{"status" => "error"} = update, previous) when is_map(previous) do
    previous_results = Map.get(previous, "results", [])

    if previous["status"] == "ok" and is_list(previous_results) and previous_results != [] do
      update
      |> Map.put("results", previous_results)
      |> Map.put("stale", true)
      |> Map.put("stale_reason", Map.get(update, "error") || "frame_refresh_failed")
      |> Map.put("last_success_status", "ok")
    else
      update
    end
  end

  defp preserve_previous_results_on_error(update, _previous), do: update

  defp refresh_ms(value) when is_integer(value), do: value |> max(@min_refresh_ms) |> min(@max_refresh_ms)

  defp refresh_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> refresh_ms(int)
      _ -> @default_refresh_ms
    end
  end

  defp refresh_ms(_value), do: @default_refresh_ms

  defp frame_summary(frame) when is_map(frame) do
    %{
      "id" => frame["id"],
      "status" => frame["status"],
      "encoding" => frame["encoding"],
      "requested_encoding" => frame["requested_encoding"],
      "row_count" => frame |> Map.get("results", []) |> row_count(),
      "byte_length" => Map.get(frame, "byte_length")
    }
  end

  defp frame_summary(_frame), do: %{"id" => nil, "status" => "error", "row_count" => 0}

  defp row_count(results) when is_list(results), do: length(results)
  defp row_count(_results), do: 0

  defp prepare_frame_transport(frames) do
    frames
    |> Enum.map_reduce([], fn
      %{"encoding" => "arrow_ipc", "payload_encoding" => "base64", "payload" => payload} = frame, binary_frames
      when is_binary(payload) ->
        metadata =
          frame
          |> Map.drop(["payload", "payload_encoding"])
          |> Map.put("payload_transport", "channel_binary")

        {metadata, [frame | binary_frames]}

      frame, binary_frames ->
        {frame, binary_frames}
    end)
    |> then(fn {metadata_frames, binary_frames} -> {metadata_frames, Enum.reverse(binary_frames)} end)
  end

  defp encode_binary_frame(%{"id" => id, "payload" => payload} = frame) when is_binary(id) and is_binary(payload) do
    payload = Base.decode64!(payload)
    metadata = frame |> Map.drop(["payload", "payload_encoding"]) |> Jason.encode!()
    id_size = byte_size(id)
    metadata_size = byte_size(metadata)

    <<
      @binary_magic::binary,
      id_size::unsigned-integer-size(16),
      metadata_size::unsigned-integer-size(32),
      id::binary,
      metadata::binary,
      payload::binary
    >>
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(_reason), do: "dashboard_stream_error"
end
