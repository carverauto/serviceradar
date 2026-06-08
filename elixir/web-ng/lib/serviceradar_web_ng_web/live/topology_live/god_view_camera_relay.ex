defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewCameraRelay do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3]

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNG.RBAC

  require Logger

  @camera_relay_poll_interval_ms 1_000
  @camera_relay_tile_limit 4

  def open(socket, params) when is_map(params) do
    scope = socket.assigns.current_scope
    camera_source_id = Map.get(params, "camera_source_id")
    stream_profile_id = Map.get(params, "stream_profile_id")
    insecure_skip_verify = parse_bool_param(params["insecure_skip_verify"]) == true

    cond do
      not can_view_device?(scope) ->
        context = selected_camera_context(params)

        socket
        |> assign(:selected_camera_context, context)
        |> assign(:camera_relay_viewer_state, viewer_state_from_error(:forbidden))
        |> put_flash(:error, "You are not authorized to start a camera relay")

      not is_nil(socket.assigns.active_camera_relay_session) ->
        put_flash(socket, :error, "Close the current camera relay before starting another")

      true ->
        with {:ok, camera_source_id} <- normalize_uuid_param(camera_source_id),
             {:ok, stream_profile_id} <- normalize_uuid_param(stream_profile_id),
             {:ok, session} <-
               relay_session_manager().request_open(
                 camera_source_id,
                 stream_profile_id,
                 scope: scope,
                 insecure_skip_verify: insecure_skip_verify
               ) do
          context = selected_camera_context(params)

          socket
          |> clear_flash(:error)
          |> assign(:selected_camera_context, context)
          |> assign(:active_camera_relay_session, session)
          |> assign(:last_camera_relay_session, nil)
          |> assign(:camera_relay_viewer_state, nil)
          |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
          |> put_flash(:info, "Camera relay requested from topology")
        else
          {:error, reason} ->
            context = selected_camera_context(params)

            socket
            |> assign(:selected_camera_context, context)
            |> assign(:camera_relay_viewer_state, viewer_state_from_error(reason))
            |> put_flash(:error, format_camera_relay_error(reason))
        end
    end
  end

  def open(socket, _params), do: open(socket, %{})

  def close(socket) do
    scope = socket.assigns.current_scope
    active_session = socket.assigns.active_camera_relay_session

    cond do
      not can_view_device?(scope) ->
        socket
        |> assign(:camera_relay_viewer_state, viewer_state_from_error(:forbidden))
        |> put_flash(:error, "You are not authorized to stop a camera relay")

      is_nil(active_session) ->
        socket

      true ->
        case relay_session_manager().request_close(
               active_session.id,
               reason: "viewer closed topology view",
               scope: scope
             ) do
          {:ok, session} ->
            socket
            |> assign(:active_camera_relay_session, session)
            |> assign(:camera_relay_viewer_state, viewer_state_from_session(session))
            |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
            |> put_flash(:info, "Camera relay closing")

          {:error, reason} ->
            put_flash(socket, :error, format_camera_relay_error(reason))
        end
    end
  end

  def open_cluster(socket, camera_tiles, params) when is_map(params) do
    open_camera_relay_cluster(socket, socket.assigns.current_scope, camera_tiles, params)
  end

  def close_tile(socket, relay_session_id) do
    close_camera_relay_tile(socket, socket.assigns.current_scope, relay_session_id)
  end

  def dismiss_tile(socket, tile_id) do
    update(socket, :camera_relay_tiles, fn tiles ->
      Enum.reject(tiles, &(Map.get(&1, :tile_id) == tile_id))
    end)
  end

  def close_tile_set(socket) do
    scope = socket.assigns.current_scope

    if can_view_device?(scope) do
      maybe_close_camera_relay_tiles(socket.assigns.camera_relay_tiles, scope, "viewer closed topology tile set")

      socket
      |> assign(:camera_relay_tile_notice, "Cluster camera relays closing")
      |> assign(:camera_relay_tiles, mark_camera_relay_tiles_closing(socket.assigns.camera_relay_tiles))
    else
      socket
      |> assign(:camera_relay_tile_notice, "You are not authorized to stop cluster camera relays")
      |> put_flash(:error, "You are not authorized to stop cluster camera relays")
    end
  end

  def refresh(socket, relay_session_id) do
    current_session =
      socket.assigns.active_camera_relay_session || socket.assigns.last_camera_relay_session

    if is_map(current_session) and Map.get(current_session, :id) == relay_session_id do
      refresh_active_camera_relay_session(socket, relay_session_id)
    else
      refresh_camera_relay_tile_session(socket, relay_session_id)
    end
  end

  defp can_view_device?(scope), do: RBAC.can?(scope, "devices.view")

  defp relay_session_terminal?(%{status: status}), do: status in [:closed, :failed, "closed", "failed"]
  defp relay_session_terminal?(_session), do: false

  defp apply_camera_relay_session_update(socket, session) do
    viewer_state = viewer_state_from_session(session)

    if relay_session_terminal?(session) do
      socket
      |> assign(:active_camera_relay_session, nil)
      |> assign(:last_camera_relay_session, session)
      |> assign(:camera_relay_viewer_state, viewer_state)
    else
      schedule_camera_relay_refresh(session.id)

      socket
      |> assign(:active_camera_relay_session, session)
      |> assign(:last_camera_relay_session, nil)
      |> assign(:camera_relay_viewer_state, viewer_state)
    end
  end

  defp schedule_camera_relay_refresh(relay_session_id) when is_binary(relay_session_id) do
    Process.send_after(self(), {:refresh_camera_relay_session, relay_session_id}, camera_relay_poll_interval_ms())
  end

  defp schedule_camera_relay_refresh(_relay_session_id), do: :ok

  defp camera_relay_poll_interval_ms do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, @camera_relay_poll_interval_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end

  defp relay_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp fetch_camera_relay_session(scope, relay_session_id) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn id, opts -> RelaySession.get_by_id(id, opts) end
      )

    fetcher.(relay_session_id, scope: scope)
  end

  defp normalize_uuid_param(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp normalize_uuid_param(_value), do: {:error, :invalid_uuid}

  defp parse_bool_param(value) when value in [true, false], do: value
  defp parse_bool_param("true"), do: true
  defp parse_bool_param("false"), do: false
  defp parse_bool_param("on"), do: true
  defp parse_bool_param("1"), do: true
  defp parse_bool_param("0"), do: false
  defp parse_bool_param(_value), do: nil

  defp format_camera_relay_error({:agent_offline, _agent_id}), do: "Assigned agent is offline for this camera source"
  defp format_camera_relay_error(:forbidden), do: "You are not authorized for camera relay access"
  defp format_camera_relay_error(:invalid_uuid), do: "Invalid camera relay request"
  defp format_camera_relay_error(reason) when is_binary(reason), do: reason
  defp format_camera_relay_error(reason), do: inspect(reason)

  defp viewer_state_from_session(%{status: status} = session) when status in [:failed, "failed"] do
    reason = Map.get(session, :failure_reason) || Map.get(session, :close_reason) || "camera relay failed"
    viewer_state_from_error(reason)
  end

  defp viewer_state_from_session(_session), do: nil

  defp viewer_state_from_error(:forbidden) do
    %{
      kind: :unauthorized,
      title: "Not Authorized",
      detail: "This viewer does not have permission to open or control camera relays from topology.",
      hint: "Use an account with device viewing access before retrying."
    }
  end

  defp viewer_state_from_error(:invalid_uuid) do
    %{
      kind: :relay_error,
      title: "Invalid Camera Request",
      detail: "The selected topology camera action did not include a valid relay identifier.",
      hint: "Refresh topology data and retry from the camera node details panel."
    }
  end

  defp viewer_state_from_error({:agent_offline, agent_id}) do
    %{
      kind: :unavailable,
      title: "Camera Relay Unavailable",
      detail: "Assigned agent #{agent_id} is offline and cannot open the camera relay.",
      hint: "Verify the edge agent and gateway are connected before retrying."
    }
  end

  defp viewer_state_from_error(reason) when is_binary(reason) do
    normalized_reason = String.trim(reason)
    classification = classify_camera_relay_issue(normalized_reason)

    case classification do
      :auth_required ->
        %{
          kind: :auth_required,
          title: "Camera Authentication Required",
          detail: normalized_reason,
          hint: "Update camera credentials or source configuration, then retry the relay."
        }

      :unavailable ->
        %{
          kind: :unavailable,
          title: "Camera Relay Unavailable",
          detail: normalized_reason,
          hint: "Check camera reachability, assigned agent/gateway health, and inventory assignment."
        }

      :unauthorized ->
        %{
          kind: :unauthorized,
          title: "Not Authorized",
          detail: normalized_reason,
          hint: "Use an account with camera relay access before retrying."
        }

      :relay_error ->
        %{
          kind: :relay_error,
          title: "Camera Relay Error",
          detail: normalized_reason,
          hint: "Review relay logs and the assigned agent/gateway path for the failure."
        }
    end
  end

  defp viewer_state_from_error(reason), do: viewer_state_from_error(inspect(reason))

  defp classify_camera_relay_issue(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    cond do
      String.contains?(downcased, ["forbidden", "unauthorized", "not authorized"]) ->
        :unauthorized

      String.contains?(downcased, ["auth", "credential", "forbidden by camera", "access denied"]) ->
        :auth_required

      String.contains?(downcased, [
        "offline",
        "not assigned",
        "unavailable",
        "inactive",
        "streamable",
        "not found",
        "reach",
        "gateway",
        "agent"
      ]) ->
        :unavailable

      true ->
        :relay_error
    end
  end

  defp normalize_camera_tile_params(camera_tiles) when is_list(camera_tiles) do
    camera_tiles
    |> Enum.reduce([], fn tile, acc ->
      case normalize_camera_tile_param(tile) do
        nil -> acc
        normalized -> [normalized | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.camera_source_id, &1.stream_profile_id})
  end

  defp normalize_camera_tile_params(_camera_tiles), do: []

  defp normalize_camera_tile_param(%{} = tile) do
    with {:ok, camera_source_id} <-
           normalize_uuid_param(Map.get(tile, "camera_source_id") || Map.get(tile, :camera_source_id)),
         {:ok, stream_profile_id} <-
           normalize_uuid_param(Map.get(tile, "stream_profile_id") || Map.get(tile, :stream_profile_id)) do
      %{
        camera_source_id: camera_source_id,
        stream_profile_id: stream_profile_id,
        device_uid: normalize_presence(Map.get(tile, "device_uid") || Map.get(tile, :device_uid)),
        camera_label: normalize_presence(Map.get(tile, "camera_label") || Map.get(tile, :camera_label)),
        profile_label: normalize_presence(Map.get(tile, "profile_label") || Map.get(tile, :profile_label)),
        insecure_skip_verify:
          parse_bool_param(Map.get(tile, "insecure_skip_verify") || Map.get(tile, :insecure_skip_verify)) == true
      }
    else
      {:error, _reason} -> nil
    end
  end

  defp normalize_camera_tile_param(_tile), do: nil

  defp build_camera_relay_tile(tile, opts) when is_map(tile) do
    relay_session = Keyword.get(opts, :session)
    viewer_state = Keyword.get(opts, :viewer_state)

    %{
      tile_id:
        if(is_map(relay_session) and is_binary(Map.get(relay_session, :id)),
          do: relay_session.id,
          else: "tile-" <> Ecto.UUID.generate()
        ),
      relay_session: relay_session,
      viewer_state: viewer_state,
      device_uid: Map.get(tile, :device_uid),
      camera_label: Map.get(tile, :camera_label),
      profile_label: Map.get(tile, :profile_label)
    }
  end

  defp camera_relay_tile_limit do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_tile_limit, @camera_relay_tile_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_tile_limit
    end
  end

  defp maybe_close_camera_relay_tiles(camera_relay_tiles, scope, reason)
       when is_list(camera_relay_tiles) and is_binary(reason) do
    Enum.each(camera_relay_tiles, fn tile ->
      case camera_relay_tile_session_id(tile) do
        relay_session_id when is_binary(relay_session_id) ->
          _ =
            relay_session_manager().request_close(
              relay_session_id,
              reason: reason,
              scope: scope
            )

          :ok

        _other ->
          :ok
      end
    end)
  end

  defp maybe_close_camera_relay_tiles(_camera_relay_tiles, _scope, _reason), do: :ok

  defp mark_camera_relay_tiles_closing(camera_relay_tiles) when is_list(camera_relay_tiles) do
    Enum.map(camera_relay_tiles, fn tile ->
      case Map.get(tile, :relay_session) do
        %{status: status} = session when status not in [:closed, :failed, "closed", "failed"] ->
          tile
          |> Map.put(:relay_session, Map.put(session, :status, :closing))
          |> Map.put(:viewer_state, viewer_state_from_session(Map.put(session, :status, :closing)))

        _other ->
          tile
      end
    end)
  end

  defp mark_camera_relay_tiles_closing(_camera_relay_tiles), do: []

  defp cluster_camera_tile_notice(opened_tiles, omitted_count, params)
       when is_list(opened_tiles) and is_integer(omitted_count) and is_map(params) do
    cluster_label =
      params
      |> Map.get("cluster_label")
      |> normalize_presence()

    active_count = Enum.count(opened_tiles, &camera_relay_tile_active?/1)

    base =
      if present?(cluster_label),
        do: "Opened #{active_count} camera relays from #{cluster_label}.",
        else: "Opened #{active_count} camera relays from the selected cluster."

    if omitted_count > 0 do
      "#{base} #{omitted_count} additional cameras were skipped to stay within the tile limit."
    else
      base
    end
  end

  defp cluster_camera_tile_notice(_opened_tiles, _omitted_count, _params), do: nil

  defp cluster_camera_tile_flash_message(opened_tiles, omitted_count)
       when is_list(opened_tiles) and is_integer(omitted_count) do
    active_count = Enum.count(opened_tiles, &camera_relay_tile_active?/1)

    if omitted_count > 0 do
      "Opened #{active_count} camera relays. #{omitted_count} were skipped to stay within the tile limit."
    else
      "Opened #{active_count} camera relays from the selected cluster"
    end
  end

  defp fetch_camera_relay_tile_session(camera_relay_tiles, relay_session_id)
       when is_list(camera_relay_tiles) and is_binary(relay_session_id) do
    Enum.find(camera_relay_tiles, &(camera_relay_tile_session_id(&1) == relay_session_id))
  end

  defp fetch_camera_relay_tile_session(_camera_relay_tiles, _relay_session_id), do: nil

  defp update_camera_relay_tile(socket, relay_session_id, updater)
       when is_binary(relay_session_id) and is_function(updater, 1) do
    update(socket, :camera_relay_tiles, fn tiles ->
      Enum.map(tiles, &maybe_update_camera_relay_tile(&1, relay_session_id, updater))
    end)
  end

  defp open_camera_relay_cluster(socket, scope, camera_tiles, params) do
    if can_view_device?(scope) do
      open_authorized_camera_relay_cluster(socket, scope, camera_tiles, params)
    else
      socket
      |> assign(:camera_relay_tile_notice, "You are not authorized to start cluster camera relays")
      |> put_flash(:error, "You are not authorized to start cluster camera relays")
    end
  end

  defp open_authorized_camera_relay_cluster(socket, scope, camera_tiles, params) do
    requested_tiles = normalize_camera_tile_params(camera_tiles)
    tile_limit = camera_relay_tile_limit()
    limited_tiles = Enum.take(requested_tiles, tile_limit)
    omitted_count = max(length(requested_tiles) - length(limited_tiles), 0)

    case limited_tiles do
      [] ->
        socket
        |> assign(:camera_relay_tile_notice, "No valid camera relays were available for this cluster")
        |> put_flash(:error, "No valid camera relays were available for this cluster")

      _ ->
        maybe_close_camera_relay_tiles(
          socket.assigns.camera_relay_tiles,
          scope,
          "replaced by a new topology tile set"
        )

        opened_tiles = open_cluster_camera_relay_tiles(limited_tiles, scope)
        notice = cluster_camera_tile_notice(opened_tiles, omitted_count, params)

        socket
        |> assign(:camera_relay_tiles, opened_tiles)
        |> assign(:camera_relay_tile_notice, notice)
        |> put_flash(:info, cluster_camera_tile_flash_message(opened_tiles, omitted_count))
    end
  end

  defp open_cluster_camera_relay_tiles(limited_tiles, scope) when is_list(limited_tiles) do
    Enum.map(limited_tiles, &open_cluster_camera_relay_tile(&1, scope))
  end

  defp open_cluster_camera_relay_tile(tile, scope) when is_map(tile) do
    case relay_session_manager().request_open(
           tile.camera_source_id,
           tile.stream_profile_id,
           scope: scope,
           insecure_skip_verify: tile.insecure_skip_verify
         ) do
      {:ok, session} ->
        schedule_camera_relay_refresh(session.id)
        build_camera_relay_tile(tile, session: session)

      {:error, reason} ->
        build_camera_relay_tile(tile, viewer_state: viewer_state_from_error(reason))
    end
  end

  defp close_camera_relay_tile(socket, scope, relay_session_id) do
    if can_view_device?(scope) do
      close_authorized_camera_relay_tile(socket, scope, relay_session_id)
    else
      socket
      |> assign(:camera_relay_tile_notice, "You are not authorized to stop cluster camera relays")
      |> put_flash(:error, "You are not authorized to stop cluster camera relays")
    end
  end

  defp close_authorized_camera_relay_tile(socket, scope, relay_session_id) do
    with {:ok, normalized_id} <- normalize_uuid_param(relay_session_id),
         {:ok, session} <-
           relay_session_manager().request_close(
             normalized_id,
             reason: "viewer closed topology tile",
             scope: scope
           ) do
      schedule_camera_relay_refresh(session.id)

      update_camera_relay_tile(socket, session.id, fn tile ->
        tile
        |> Map.put(:relay_session, session)
        |> Map.put(:viewer_state, viewer_state_from_session(session))
      end)
    else
      {:error, :invalid_uuid} ->
        socket

      {:error, reason} ->
        socket
        |> assign(:camera_relay_tile_notice, format_camera_relay_error(reason))
        |> put_flash(:error, format_camera_relay_error(reason))
    end
  end

  defp refresh_active_camera_relay_session(socket, relay_session_id) do
    case fetch_camera_relay_session(socket.assigns.current_scope, relay_session_id) do
      {:ok, nil} ->
        assign(socket, :active_camera_relay_session, nil)

      {:ok, session} ->
        apply_camera_relay_session_update(socket, session)

      {:error, reason} ->
        Logger.warning("Topology camera relay refresh failed for #{relay_session_id}: #{inspect(reason)}")

        assign(socket, :camera_relay_viewer_state, viewer_state_from_error(reason))
    end
  end

  defp refresh_camera_relay_tile_session(socket, relay_session_id) do
    case fetch_camera_relay_tile_session(socket.assigns.camera_relay_tiles, relay_session_id) do
      nil ->
        socket

      _tile ->
        apply_camera_relay_tile_refresh(
          socket,
          relay_session_id,
          fetch_camera_relay_session(socket.assigns.current_scope, relay_session_id)
        )
    end
  end

  defp apply_camera_relay_tile_refresh(socket, relay_session_id, {:ok, nil}) do
    update(socket, :camera_relay_tiles, fn tiles ->
      Enum.reject(tiles, &(camera_relay_tile_session_id(&1) == relay_session_id))
    end)
  end

  defp apply_camera_relay_tile_refresh(socket, relay_session_id, {:ok, session}) do
    update_camera_relay_tile(socket, relay_session_id, fn tile ->
      tile
      |> Map.put(:relay_session, session)
      |> Map.put(:viewer_state, viewer_state_from_session(session))
    end)
  end

  defp apply_camera_relay_tile_refresh(socket, relay_session_id, {:error, reason}) do
    Logger.warning("Topology camera relay tile refresh failed for #{relay_session_id}: #{inspect(reason)}")

    update_camera_relay_tile(socket, relay_session_id, fn tile ->
      Map.put(tile, :viewer_state, viewer_state_from_error(reason))
    end)
  end

  defp maybe_update_camera_relay_tile(tile, relay_session_id, updater) do
    if camera_relay_tile_session_id(tile) == relay_session_id do
      updater.(tile)
    else
      tile
    end
  end

  defp camera_relay_tile_session_id(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:id)
  end

  defp camera_relay_tile_active?(tile) do
    session = Map.get(tile, :relay_session)
    is_map(session) and not relay_session_terminal?(session)
  end

  defp selected_camera_context(params) when is_map(params) do
    %{
      device_uid: normalize_presence(Map.get(params, "device_uid")),
      camera_label: normalize_presence(Map.get(params, "camera_label")),
      profile_label: normalize_presence(Map.get(params, "profile_label"))
    }
  end

  defp normalize_presence(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_presence(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
