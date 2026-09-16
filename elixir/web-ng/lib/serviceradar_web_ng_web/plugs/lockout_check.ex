defmodule ServiceRadarWebNGWeb.Plugs.LockoutCheck do
  @moduledoc """
  Short-circuits the request when the actor's account is currently
  locked.

  The plug reads the actor identifier from a configurable param (for
  password endpoints) or assign (for endpoints that have already
  populated `:current_user`/`:current_scope`). On a hit it emits a
  `:policy_denied` `SecurityEvent` for observability and halts with
  either:

    * HTTP 423 + `{"error":"account_temporarily_locked"}` for JSON
      callers, or
    * HTTP 303 + flash + redirect to a configurable sign-in path for
      HTML callers.

  The HTML / JSON branch is picked by `:response_mode` (defaults to
  `:auto`, which sniffs the request's `accept` header).

  ## Options

    * `:actor_id_param` — params key to read the actor identifier
      from (e.g. `"email"` for a password sign-in form). Optional.
    * `:actor_id_assign` — conn assign key to read the actor
      identifier from (e.g. `:current_user`). Optional.
    * `:assign_id_field` — when reading from an assign that's a
      struct/map, the field to pluck for the actor id. Default
      `:id`.
    * `:response_mode` — `:auto` (default), `:json`, or `:html`.
    * `:html_redirect_to` — string path (or 0-arity function
      returning a path) for the HTML redirect. Default
      `"/users/log-in"`.
    * `:html_flash` — flash message for HTML responses. Default
      "Account temporarily locked. Try again later."
    * `:json_body_builder` — optional 0-arity function returning
      iodata. When set and the resolved response mode is `:json`,
      the plug uses the function's return value as the 423 body
      verbatim instead of the default
      `{"error":"account_temporarily_locked"}`. Builder failures
      fall back to the default body and emit a logger warning.

  At least one of `:actor_id_param` / `:actor_id_assign` is required.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadarWebNGWeb.ClientIP

  @default_html_redirect "/users/log-in"
  @default_html_flash "Account temporarily locked. Try again later."

  @impl true
  def init(opts) do
    param = Keyword.get(opts, :actor_id_param)
    assign = Keyword.get(opts, :actor_id_assign)
    id_field = Keyword.get(opts, :assign_id_field, :id)
    response_mode = Keyword.get(opts, :response_mode, :auto)
    body_builder = Keyword.get(opts, :json_body_builder)

    if is_nil(param) and is_nil(assign) do
      raise ArgumentError,
            "LockoutCheck: requires :actor_id_param or :actor_id_assign"
    end

    if response_mode not in [:auto, :json, :html] do
      raise ArgumentError,
            "LockoutCheck :response_mode must be :auto, :json, or :html (got #{inspect(response_mode)})"
    end

    if !(is_nil(body_builder) or is_function(body_builder, 0)) do
      raise ArgumentError,
            "LockoutCheck :json_body_builder must be a 0-arity function or nil (got #{inspect(body_builder)})"
    end

    %{
      param: param,
      assign: assign,
      id_field: id_field,
      response_mode: response_mode,
      html_redirect_to: Keyword.get(opts, :html_redirect_to, @default_html_redirect),
      html_flash: Keyword.get(opts, :html_flash, @default_html_flash),
      json_body_builder: body_builder
    }
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
            |> respond_locked(config)
            |> halt()
        end
    end
  end

  ## Response builders

  defp respond_locked(conn, config) do
    case resolve_mode(conn, config.response_mode) do
      :html ->
        conn
        |> maybe_put_flash(:error, config.html_flash)
        |> put_resp_header("location", resolve_redirect(config.html_redirect_to))
        |> send_resp(303, "")

      :json ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(423, json_body(config.json_body_builder))
    end
  end

  defp json_body(nil), do: default_json_body()

  defp json_body(builder) when is_function(builder, 0) do
    builder.()
  rescue
    e ->
      require Logger

      Logger.warning("LockoutCheck :json_body_builder raised: #{Exception.message(e)}")
      default_json_body()
  end

  defp default_json_body, do: ~s({"error":"account_temporarily_locked"})

  defp resolve_mode(_conn, :json), do: :json
  defp resolve_mode(_conn, :html), do: :html

  defp resolve_mode(conn, :auto) do
    if html_preferred?(conn), do: :html, else: :json
  end

  defp html_preferred?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "text/html")
      [] -> false
    end
  end

  defp resolve_redirect(fun) when is_function(fun, 0), do: fun.()
  defp resolve_redirect(path) when is_binary(path), do: path

  defp maybe_put_flash(conn, key, message) do
    if Map.has_key?(conn.private, :phoenix_flash) do
      Phoenix.Controller.put_flash(conn, key, message)
    else
      conn
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

  # Centralized extraction: honors x-forwarded-for only from trusted
  # proxies (see ServiceRadarWebNG.ClientIP).
  defp client_ip(conn), do: ClientIP.get(conn)
end
