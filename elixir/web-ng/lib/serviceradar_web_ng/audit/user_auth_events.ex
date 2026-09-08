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

  @doc """
  Records which role mappings matched at sign-in, and what they granted.

  Answers "why does this user have the access they have" -- a question the
  previous resolver made unanswerable, because it returned a bare role atom and
  kept nothing about which mapping produced it. Written once per SSO sign-in
  where at least one mapping matched.

  Group names and profile ids are recorded; no claim payload is, since a claim
  set can carry far more about a person than the mapping decision needs.
  """
  def record_role_mapping(user, resolution, auth_method) do
    actor = SystemActor.system(:user_auth_events)

    attrs = %{
      user_id: user.id,
      actor_user_id: user.id,
      event_type: "role_mapping",
      auth_method: to_string(auth_method || ""),
      metadata: %{
        "resolved_role" => to_string(resolution.role),
        "role_profile_ids" => resolution.role_profile_ids,
        "user_group_ids" => resolution.user_group_ids,
        "matched" => Enum.map(resolution.matched, &summarize_mapping/1)
      }
    }

    UserAuthEvent
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, _event} -> :ok
      {:error, _reason} -> :error
    end
  end

  # Only the fields that decide the outcome. A mapping is operator-authored
  # configuration, not user data, so recording it verbatim is safe -- but the
  # claims it matched against are not, and are deliberately absent.
  defp summarize_mapping(mapping) do
    Map.new(["source", "value", "claim", "role", "role_profile_id", "user_group_id"], fn key ->
      {key, mapping |> Map.get(key) |> normalize_metadata_value()}
    end)
  end

  defp normalize_metadata_value(nil), do: nil
  defp normalize_metadata_value(value) when is_binary(value), do: value
  defp normalize_metadata_value(value), do: to_string(value)

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
