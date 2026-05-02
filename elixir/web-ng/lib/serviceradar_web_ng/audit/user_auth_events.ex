defmodule ServiceRadarWebNG.Audit.UserAuthEvents do
  @moduledoc """
  Write user auth/audit events with request context (IP, user-agent).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.UserAuthEvent
  alias ServiceRadarWebNG.ClientIP

  def record_login(%Plug.Conn{} = conn, user, auth_method) do
    record(conn, user, "login", auth_method)
  end

  def record_login_context(user, auth_method, ip, user_agent) do
    record_context(user, "login", auth_method, ip, user_agent)
  end

  def record_logout(%Plug.Conn{} = conn, user, auth_method) do
    record(conn, user, "logout", auth_method)
  end

  defp record(conn, user, event_type, auth_method) do
    actor = SystemActor.system(:user_auth_events)

    attrs = %{
      user_id: user.id,
      actor_user_id: user.id,
      event_type: event_type,
      auth_method: to_string(auth_method || ""),
      ip: client_ip(conn),
      user_agent: user_agent(conn)
    }

    UserAuthEvent
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  defp record_context(user, event_type, auth_method, ip, user_agent) do
    actor = SystemActor.system(:user_auth_events)

    attrs = %{
      user_id: user.id,
      actor_user_id: user.id,
      event_type: event_type,
      auth_method: to_string(auth_method || ""),
      ip: ip,
      user_agent: user_agent
    }

    UserAuthEvent
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  defp client_ip(conn) do
    ClientIP.get(conn)
  end

  defp user_agent(conn) do
    conn
    |> Plug.Conn.get_req_header("user-agent")
    |> List.first()
  end
end
