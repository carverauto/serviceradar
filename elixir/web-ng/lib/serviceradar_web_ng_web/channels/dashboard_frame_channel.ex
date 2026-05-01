defmodule ServiceRadarWebNGWeb.DashboardFrameChannel do
  @moduledoc false
  use Phoenix.Channel

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.FrameRunner
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
         {:ok, %DashboardInstance{}} <-
           Dashboards.get_enabled_instance_by_slug(route_slug, scope: socket.assigns.current_scope) do
      socket =
        socket
        |> assign(:route_slug, route_slug)
        |> assign(:data_frames, normalize_data_frames(stream["data_frames"] || stream[:data_frames]))
        |> assign(:refresh_ms, refresh_ms(payload["refresh_interval_ms"]))
        |> assign(:last_frame_hash, nil)

      send(self(), :dashboard_frame_tick)
      {:ok, %{"refresh_interval_ms" => socket.assigns.refresh_ms}, socket}
    else
      false -> {:error, %{reason: "unauthorized"}}
      {:error, :invalid_route} -> {:error, %{reason: "invalid_stream"}}
      {:error, :not_found} -> {:error, %{reason: "dashboard_unavailable"}}
      {:error, reason} -> {:error, %{reason: format_error(reason)}}
    end
  end

  def join("dashboards:" <> _route_slug, _payload, _socket), do: {:error, %{reason: "missing_stream_token"}}

  @impl true
  def handle_info(:dashboard_frame_tick, socket) do
    socket = push_frame_snapshot(socket)
    Process.send_after(self(), :dashboard_frame_tick, socket.assigns.refresh_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_in("frames:refresh", _payload, socket) do
    {:reply, {:ok, %{}}, push_frame_snapshot(assign(socket, :last_frame_hash, nil))}
  end

  defp push_frame_snapshot(socket) do
    frames = FrameRunner.run(socket.assigns.data_frames, socket.assigns.current_scope)
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

      assign(socket, :last_frame_hash, hash)
    end
  rescue
    error ->
      Logger.error("dashboard frame stream failed route_slug=#{socket.assigns[:route_slug]} error=#{inspect(error)}")
      push(socket, "frames:error", %{"reason" => "frame_stream_unavailable"})
      socket
  end

  def stream_token(route_slug, data_frames) when is_binary(route_slug) and is_list(data_frames) do
    Phoenix.Token.sign(Endpoint, @stream_salt, %{
      "route_slug" => route_slug,
      "data_frames" => data_frames
    })
  end

  defp verify_stream_token(token) when is_binary(token) do
    Phoenix.Token.verify(Endpoint, @stream_salt, token, max_age: @stream_token_max_age)
  end

  defp verify_stream_token(_token), do: {:error, :invalid_stream}

  defp verify_route_slug(route_slug, %{"route_slug" => route_slug}), do: :ok
  defp verify_route_slug(route_slug, %{route_slug: route_slug}), do: :ok
  defp verify_route_slug(_route_slug, _stream), do: {:error, :invalid_route}

  defp normalize_data_frames(data_frames) when is_list(data_frames), do: data_frames
  defp normalize_data_frames(_data_frames), do: []

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
