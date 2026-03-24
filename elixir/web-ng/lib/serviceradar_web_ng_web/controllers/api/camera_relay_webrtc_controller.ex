defmodule ServiceRadarWebNGWeb.Api.CameraRelayWebRTCController do
  @moduledoc """
  Authenticated API for relay-scoped WebRTC signaling.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.CameraRelayWebRTC
  alias ServiceRadarWebNGWeb.Api.CameraRelaySessionController

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  def create_session(conn, %{"id" => relay_session_id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_id} <- CameraRelaySessionController.normalize_uuid_param(relay_session_id, "id") do
      scope = get_scope(conn)

      case CameraRelaySessionController.fetch_relay_session_for_scope(normalized_id, scope) do
        {:ok, relay_session} ->
          case CameraRelayWebRTC.create_session(normalized_id, scope: scope) do
            {:ok, signal_session} ->
              conn
              |> put_status(:created)
              |> json(%{data: create_session_json(normalized_id, signal_session)})

            {:error, :not_found} ->
              render_missing_or_activating(conn, relay_session)

            {:error, :viewer_session_not_found} ->
              conn
              |> put_status(:not_found)
              |> json(%{
                error: "viewer_session_not_found",
                message: "webrtc viewer session was not found"
              })

            {:error, reason} when is_binary(reason) ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "webrtc_unavailable", message: reason})

            {:error, other} ->
              {:error, other}
          end

        {:error, :not_found} ->
          render_missing_or_activating(conn, nil)

        {:error, other} ->
          {:error, other}
      end
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  def submit_answer(conn, %{"id" => relay_session_id, "viewer_session_id" => viewer_session_id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_relay_id} <-
           CameraRelaySessionController.normalize_uuid_param(relay_session_id, "id"),
         {:ok, normalized_viewer_session_id} <-
           CameraRelaySessionController.normalize_uuid_param(viewer_session_id, "viewer_session_id"),
         {:ok, answer_sdp} <- normalize_required_string(Map.get(params, "sdp"), "sdp"),
         {:ok, _session} <-
           CameraRelaySessionController.fetch_relay_session_for_scope(normalized_relay_id, get_scope(conn)),
         {:ok, result} <-
           CameraRelayWebRTC.submit_answer(
             normalized_relay_id,
             normalized_viewer_session_id,
             answer_sdp,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{relay_session_id: normalized_relay_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "relay_session_not_found", message: "relay session was not found"})

      {:error, :viewer_session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "viewer_session_not_found", message: "webrtc viewer session was not found"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  def add_candidate(conn, %{"id" => relay_session_id, "viewer_session_id" => viewer_session_id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_relay_id} <-
           CameraRelaySessionController.normalize_uuid_param(relay_session_id, "id"),
         {:ok, normalized_viewer_session_id} <-
           CameraRelaySessionController.normalize_uuid_param(viewer_session_id, "viewer_session_id"),
         {:ok, candidate} <- normalize_candidate(params),
         {:ok, _session} <-
           CameraRelaySessionController.fetch_relay_session_for_scope(normalized_relay_id, get_scope(conn)),
         {:ok, result} <-
           CameraRelayWebRTC.add_ice_candidate(
             normalized_relay_id,
             normalized_viewer_session_id,
             candidate,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{relay_session_id: normalized_relay_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "relay_session_not_found", message: "relay session was not found"})

      {:error, :viewer_session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "viewer_session_not_found", message: "webrtc viewer session was not found"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  def close_session(conn, %{"id" => relay_session_id, "viewer_session_id" => viewer_session_id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_relay_id} <-
           CameraRelaySessionController.normalize_uuid_param(relay_session_id, "id"),
         {:ok, normalized_viewer_session_id} <-
           CameraRelaySessionController.normalize_uuid_param(viewer_session_id, "viewer_session_id"),
         {:ok, _session} <-
           CameraRelaySessionController.fetch_relay_session_for_scope(normalized_relay_id, get_scope(conn)),
         {:ok, result} <-
           CameraRelayWebRTC.close_session(
             normalized_relay_id,
             normalized_viewer_session_id,
             scope: get_scope(conn)
           ) do
      json(conn, %{data: Map.merge(%{"relay_session_id" => normalized_relay_id}, stringify_keys(result))})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "relay_session_not_found", message: "relay session was not found"})

      {:error, :viewer_session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "viewer_session_not_found", message: "webrtc viewer session was not found"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "webrtc_unavailable", message: reason})

      {:error, other} ->
        {:error, other}
    end
  end

  defp create_session_json(relay_session_id, signal_session) do
    signal_session
    |> stringify_keys()
    |> Map.merge(%{
      "relay_session_id" => relay_session_id,
      "transport" => CameraRelayWebRTC.transport_name(),
      "signaling_path" => CameraRelayWebRTC.signaling_path(relay_session_id),
      "ice_servers" => CameraRelayWebRTC.ice_servers()
    })
  end

  defp render_missing_or_activating(conn, %{status: status})
       when status in [:requested, :opening, "requested", "opening"] do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "relay_session_activating",
      message: "relay session is still activating"
    })
  end

  defp render_missing_or_activating(conn, _relay_session) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "relay_session_not_found", message: "relay session was not found"})
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

  defp normalize_required_string(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, :invalid_request, "#{field_name} is required"}, else: {:ok, trimmed}
  end

  defp normalize_required_string(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(_other), do: %{}

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %ServiceRadarWebNG.Accounts.Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]
    if ServiceRadarWebNG.RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
