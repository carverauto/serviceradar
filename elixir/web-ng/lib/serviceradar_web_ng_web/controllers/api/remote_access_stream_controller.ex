defmodule ServiceRadarWebNGWeb.Api.RemoteAccessStreamController do
  @moduledoc """
  Browser-authenticated websocket upgrade for generic remote-access streams.
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler
  alias ServiceRadarWebNGWeb.FeatureFlags

  @remote_access_permission "devices.remote_access.ssh.open"
  @remote_access_rdp_permission "devices.remote_access.rdp.open"
  @default_browser_stream_timeout_ms to_timeout(hour: 1)

  def connect(conn, %{"id" => session_id}) do
    scope = conn.assigns[:current_scope]

    with {:ok, scope} <- require_any_stream_permission(scope),
         {:ok, normalized_id} <- normalize_uuid(session_id, "id"),
         {:ok, %RemoteAccessSession{} = session} <-
           remote_access_session_fetcher().(normalized_id, scope: scope),
         :ok <- require_session_owner(scope, session),
         :ok <- require_protocol_enabled(session),
         {:ok, scope} <- require_session_permission(scope, session) do
      adapter = websock_adapter()

      conn =
        adapter.upgrade(
          conn,
          RemoteAccessStreamHandler,
          [session_id: normalized_id, scope: scope],
          timeout: browser_stream_timeout_ms(session)
        )

      halt(conn)
    else
      {:error, :remote_access_ssh_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "SSH remote access is not enabled"})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :unsupported_remote_access_protocol} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, reason} when reason in [:forbidden, :permission_revoked] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, %NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})
    end
  end

  defp require_protocol_enabled(%RemoteAccessSession{} = session) do
    case format_value(session.protocol) do
      "rdp" ->
        if FeatureFlags.remote_access_desktop_rdp_enabled?(),
          do: :ok,
          else: {:error, :remote_access_desktop_rdp_disabled}

      "ssh" ->
        if FeatureFlags.remote_access_ssh_enabled?(),
          do: :ok,
          else: {:error, :remote_access_ssh_disabled}

      _protocol ->
        {:error, :unsupported_remote_access_protocol}
    end
  end

  defp require_any_stream_permission(scope) do
    authorization_module().authorize_current_any(scope, [
      @remote_access_permission,
      @remote_access_rdp_permission
    ])
  end

  defp require_session_permission(scope, %RemoteAccessSession{} = session) do
    with {:ok, permission} <- permission_for_session(session) do
      authorization_module().authorize_current(scope, [permission])
    end
  end

  defp require_session_owner(scope, %RemoteAccessSession{requested_by: requested_by}) do
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

  defp permission_for_session(%RemoteAccessSession{} = session) do
    case format_value(session.protocol) do
      "rdp" -> {:ok, @remote_access_rdp_permission}
      "ssh" -> {:ok, @remote_access_permission}
      _protocol -> {:error, :unsupported_remote_access_protocol}
    end
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: to_string(value)

  defp normalize_uuid(value, field_name) when is_binary(value) do
    value
    |> String.trim()
    |> Ecto.UUID.cast()
    |> case do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp browser_stream_timeout_ms(%RemoteAccessSession{} = session) do
    [
      configured_browser_stream_timeout_ms(),
      session_stream_timeout_ms(session)
    ]
    |> Enum.filter(&positive_integer?/1)
    |> Enum.min(fn -> @default_browser_stream_timeout_ms end)
  end

  defp configured_browser_stream_timeout_ms do
    case Application.get_env(
           :serviceradar_web_ng,
           :remote_access_browser_stream_timeout_ms,
           @default_browser_stream_timeout_ms
         ) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _other -> @default_browser_stream_timeout_ms
    end
  end

  defp session_stream_timeout_ms(%RemoteAccessSession{} = session) do
    [
      seconds_to_milliseconds(session.idle_timeout_seconds),
      seconds_to_milliseconds(session.absolute_timeout_seconds)
    ]
    |> Enum.filter(&positive_integer?/1)
    |> Enum.min(fn -> nil end)
  end

  defp seconds_to_milliseconds(seconds) when is_integer(seconds) and seconds > 0 do
    seconds * 1000
  end

  defp seconds_to_milliseconds(_seconds), do: nil

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp remote_access_session_fetcher do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn session_id, opts -> RemoteAccessSession.get_by_id(session_id, opts) end
    )
  end

  defp websock_adapter do
    Application.get_env(:serviceradar_web_ng, :remote_access_websock_adapter, WebSockAdapter)
  end

  defp authorization_module do
    Application.get_env(:serviceradar_web_ng, :current_user_authorization_module, RBAC)
  end
end
