defmodule ServiceRadarWebNGWeb.Api.RemoteDesktopWebRTCController do
  @moduledoc """
  Authenticated API for desktop remote-access WebRTC signaling.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteDesktopWebRTC
  alias ServiceRadarWebNGWeb.FeatureFlags

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @remote_desktop_permission "devices.remote_access.rdp.open"

  def create_session(conn, %{"id" => session_id}) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, normalized_id} <- normalize_uuid(session_id, "id"),
         {:ok, session} <- fetch_desktop_session_for_scope(normalized_id, get_scope(conn)) do
      case RemoteDesktopWebRTC.create_session(normalized_id, scope: get_scope(conn)) do
        {:ok, signal_session} ->
          conn
          |> put_status(:created)
          |> json(%{data: create_session_json(normalized_id, signal_session)})

        {:error, :not_found} ->
          render_missing_or_activating(conn, session)

        {:error, :viewer_session_not_found} ->
          render_viewer_session_not_found(conn)

        {:error, {:viewer_limit_exceeded, kind, limit}}
        when kind in [:session, :actor, :global] and is_integer(limit) ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{
            error: "desktop_webrtc_viewer_limit_exceeded",
            message: "desktop WebRTC viewer capacity is exhausted",
            scope: Atom.to_string(kind),
            limit: limit
          })

        {:error, reason} when is_binary(reason) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "desktop_webrtc_unavailable", message: reason})

        {:error, other} ->
          {:error, other}
      end
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :not_found} ->
        render_missing_or_activating(conn, nil)

      {:error, :unsupported_remote_desktop_session} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "unsupported_remote_desktop_session",
          message: "remote access session is not an RDP desktop session"
        })

      {:error, other} ->
        {:error, other}
    end
  end

  def submit_answer(conn, %{"id" => session_id, "viewer_session_id" => viewer_session_id} = params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, normalized_session_id} <- normalize_uuid(session_id, "id"),
         {:ok, normalized_viewer_session_id} <- normalize_uuid(viewer_session_id, "viewer_session_id"),
         {:ok, answer_sdp} <- normalize_required_string(Map.get(params, "sdp"), "sdp"),
         {:ok, _session} <- fetch_desktop_session_for_scope(normalized_session_id, get_scope(conn)),
         {:ok, result} <-
           RemoteDesktopWebRTC.submit_answer(
             normalized_session_id,
             normalized_viewer_session_id,
             answer_sdp,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{session_id: normalized_session_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :not_found} ->
        render_missing_or_activating(conn, nil)

      {:error, :viewer_session_not_found} ->
        render_viewer_session_not_found(conn)

      {:error, :unsupported_remote_desktop_session} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "unsupported_remote_desktop_session",
          message: "remote access session is not an RDP desktop session"
        })

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "desktop_webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  def add_candidate(conn, %{"id" => session_id, "viewer_session_id" => viewer_session_id} = params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, normalized_session_id} <- normalize_uuid(session_id, "id"),
         {:ok, normalized_viewer_session_id} <- normalize_uuid(viewer_session_id, "viewer_session_id"),
         {:ok, candidate} <- normalize_candidate(params),
         {:ok, _session} <- fetch_desktop_session_for_scope(normalized_session_id, get_scope(conn)),
         {:ok, result} <-
           RemoteDesktopWebRTC.add_ice_candidate(
             normalized_session_id,
             normalized_viewer_session_id,
             candidate,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{session_id: normalized_session_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :not_found} ->
        render_missing_or_activating(conn, nil)

      {:error, :viewer_session_not_found} ->
        render_viewer_session_not_found(conn)

      {:error, :unsupported_remote_desktop_session} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "unsupported_remote_desktop_session",
          message: "remote access session is not an RDP desktop session"
        })

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "desktop_webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  def close_session(conn, %{"id" => session_id, "viewer_session_id" => viewer_session_id}) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, normalized_session_id} <- normalize_uuid(session_id, "id"),
         {:ok, normalized_viewer_session_id} <- normalize_uuid(viewer_session_id, "viewer_session_id"),
         {:ok, _session} <- fetch_desktop_session_for_scope(normalized_session_id, get_scope(conn)),
         {:ok, result} <-
           RemoteDesktopWebRTC.close_session(
             normalized_session_id,
             normalized_viewer_session_id,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{session_id: normalized_session_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :not_found} ->
        render_missing_or_activating(conn, nil)

      {:error, :viewer_session_not_found} ->
        render_viewer_session_not_found(conn)

      {:error, :unsupported_remote_desktop_session} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "unsupported_remote_desktop_session",
          message: "remote access session is not an RDP desktop session"
        })

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "desktop_webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  defp fetch_desktop_session_for_scope(session_id, scope) do
    with {:ok, session} <- remote_access_session_fetcher().(session_id, scope: scope),
         :ok <- require_desktop_session(session),
         :ok <- require_session_owner(session, scope) do
      {:ok, session}
    end
  end

  defp require_desktop_session(nil), do: {:error, :not_found}

  defp require_desktop_session(session) do
    if value_to_string(Map.get(session, :protocol)) == "rdp" do
      :ok
    else
      {:error, :unsupported_remote_desktop_session}
    end
  end

  defp value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(_value), do: nil

  defp require_session_owner(%{requested_by: requested_by}, scope) do
    with actor_id when is_binary(actor_id) <- scope_actor_id(scope),
         owner_id when is_binary(owner_id) <- normalize_id(requested_by),
         true <- actor_id == owner_id do
      :ok
    else
      _mismatch -> {:error, :not_found}
    end
  end

  defp scope_actor_id(%{user: %{id: id}}), do: normalize_id(id)
  defp scope_actor_id(_scope), do: nil

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when not is_nil(id), do: to_string(id)
  defp normalize_id(_id), do: nil

  defp create_session_json(session_id, signal_session) do
    signal_session = stringify_keys(signal_session)

    Map.merge(signal_session, %{
      "session_id" => session_id,
      "transport" => RemoteDesktopWebRTC.transport_name(),
      "signaling_path" => RemoteDesktopWebRTC.signaling_path(session_id),
      "ice_servers" => Map.get(signal_session, "ice_servers", [])
    })
  end

  defp render_missing_or_activating(conn, %{status: status})
       when status in [:requested, :opening, "requested", "opening"] do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "remote_desktop_session_activating",
      message: "remote desktop session is still activating"
    })
  end

  defp render_missing_or_activating(conn, _session) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})
  end

  defp render_viewer_session_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "viewer_session_not_found",
      message: "webrtc viewer session was not found"
    })
  end

  defp normalize_candidate(%{"candidate" => %{} = candidate}), do: {:ok, candidate}

  defp normalize_candidate(%{"candidate" => candidate}) when is_binary(candidate) do
    normalized = String.trim(candidate)

    if normalized == "" do
      {:error, :invalid_request, "candidate is required"}
    else
      {:ok, %{"candidate" => normalized}}
    end
  end

  defp normalize_candidate(_params), do: {:error, :invalid_request, "candidate is required"}

  defp normalize_uuid(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_required_string(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, :invalid_request, "#{field_name} is required"}, else: {:ok, trimmed}
  end

  defp normalize_required_string(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(_other), do: %{}

  defp remote_access_session_fetcher do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn session_id, opts -> RemoteAccessSession.get_by_id(session_id, opts) end
    )
  end

  defp require_remote_desktop_enabled do
    if FeatureFlags.remote_access_desktop_rdp_enabled?() do
      :ok
    else
      {:error, :remote_access_desktop_rdp_disabled}
    end
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
