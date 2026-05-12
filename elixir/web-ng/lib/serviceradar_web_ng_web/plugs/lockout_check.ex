defmodule ServiceRadarWebNGWeb.Plugs.LockoutCheck do
  @moduledoc """
  Short-circuits the request when the actor's account is currently
  locked.

  The plug reads the actor identifier from a configurable param (for
  password endpoints) or assign (for endpoints that have already
  populated `:current_user`/`:current_scope`). On a hit it emits a
  `:lockout_triggered`-shaped `SecurityEvent` for observability and
  halts with a generic 423 (Locked) — no info leak about why.

  ## Options

    * `:actor_id_param` — params key to read the actor identifier
      from (e.g. `"email"` for a password sign-in form). Optional.
    * `:actor_id_assign` — conn assign key to read the actor
      identifier from (e.g. `:current_user`). Optional.
    * `:assign_id_field` — when reading from an assign that's a
      struct/map, the field to pluck for the actor id. Default
      `:id`.

  At least one of `:actor_id_param` / `:actor_id_assign` is required.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.Lockouts

  @impl true
  def init(opts) do
    param = Keyword.get(opts, :actor_id_param)
    assign = Keyword.get(opts, :actor_id_assign)
    id_field = Keyword.get(opts, :assign_id_field, :id)

    if is_nil(param) and is_nil(assign) do
      raise ArgumentError,
            "LockoutCheck: requires :actor_id_param or :actor_id_assign"
    end

    %{param: param, assign: assign, id_field: id_field}
  end

  @impl true
  def call(conn, config) do
    case actor_id(conn, config) do
      nil ->
        conn

      actor_id ->
        case Lockouts.active_lockout(actor_id) do
          nil ->
            conn

          _ ->
            emit_blocked(conn, actor_id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(423, ~s({"error":"account_temporarily_locked"}))
            |> halt()
        end
    end
  end

  defp actor_id(conn, %{param: param, assign: assign, id_field: id_field}) do
    case actor_id_from_param(conn, param) do
      nil -> actor_id_from_assign(conn, assign, id_field)
      id -> id
    end
  end

  defp actor_id_from_param(_conn, nil), do: nil

  defp actor_id_from_param(conn, param) do
    case conn.params[param] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp actor_id_from_assign(_conn, nil, _field), do: nil

  defp actor_id_from_assign(conn, assign, id_field) do
    case Map.get(conn.assigns, assign) do
      nil ->
        nil

      %{id: id} when not is_nil(id) ->
        stringify(id)

      map when is_map(map) ->
        map |> Map.get(id_field) |> stringify()

      id when is_binary(id) ->
        id

      _ ->
        nil
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp emit_blocked(conn, actor_id) do
    Events.record(%{
      kind: :policy_denied,
      severity: :warning,
      actor_id: actor_id,
      ip: client_ip(conn),
      route: conn.request_path,
      details: %{"reason" => "account_locked"}
    })
  rescue
    _ -> :ok
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",", parts: 2) |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> List.to_string()
    end
  end
end
