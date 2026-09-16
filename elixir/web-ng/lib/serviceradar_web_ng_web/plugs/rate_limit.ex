defmodule ServiceRadarWebNGWeb.Plugs.RateLimit do
  @moduledoc """
  Plug that gates incoming requests through `ServiceRadar.Security.RateLimiter`.

  Pipelines opt in by specifying a named bucket; the bucket's `limit`
  and `window_seconds` come from the core config (`ServiceRadar.Security.RateLimiter`).
  On denial the plug halts the connection with either an HTTP 303
  redirect + flash (HTML clients) or an HTTP 429 JSON body
  (programmatic clients). The `x-ratelimit-{limit,remaining,reset}`
  headers are set on every response; denials also carry `retry-after`.

  ## Options

    * `:bucket` — bucket atom, required (e.g. `:auth_local`, `:webhook_ingest`).
    * `:subject` — `:ip` (default) or `:ip_and_actor` to key the limit on
      `{ip, current_actor_id || :anonymous}` for password-spray defense.
    * `:limit`, `:window_seconds` — explicit overrides; usually unset so
      the bucket config wins.
    * `:response_mode` — `:auto` (default; sniffs the `accept` header
      for `text/html`), `:json`, or `:html`. Pipelines that are
      JSON-only should pin to `:json` so a malformed `Accept` header
      doesn't accidentally redirect a browser-shaped request.
    * `:html_redirect_to` — string path or 0-arity function returning a
      path. Used when `:response_mode` resolves to `:html`. Default
      `"/users/log-in"`.
    * `:html_flash_template` — string with optional `{retry_after}`
      placeholder. Default "Too many attempts. Please try again in
      {retry_after} seconds."
    * `:json_body_builder` — optional 1-arity function
      `(retry_after :: pos_integer) -> iodata`. When set and the
      resolved response mode is `:json`, the plug uses the
      function's return value as the 429 body verbatim instead of
      the default `{"error":"rate_limited","retry_after":N}`.
      Builder failures fall back to the default body and emit a
      logger warning so a broken builder never breaks the request
      path.

  Place this plug after `:fetch_session` (and `:fetch_live_flash` for
  HTML pipelines) and any auth plug that puts the current user/actor
  into the conn assigns; otherwise the `:ip_and_actor` subject
  collapses to `{ip, :anonymous}`.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.ClientIP

  @default_html_redirect "/users/log-in"
  # The template uses a literal `{retry_after}` placeholder (no `\#`) —
  # `render_flash/2` swaps it for the integer at call time.
  @default_html_flash "Too many attempts. Please try again in {retry_after} seconds."

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    subject = Keyword.get(opts, :subject, :ip)
    limit = Keyword.get(opts, :limit)
    window = Keyword.get(opts, :window_seconds)
    response_mode = Keyword.get(opts, :response_mode, :auto)
    body_builder = Keyword.get(opts, :json_body_builder)

    if response_mode not in [:auto, :json, :html] do
      raise ArgumentError,
            "RateLimit :response_mode must be :auto, :json, or :html (got #{inspect(response_mode)})"
    end

    if !(is_nil(body_builder) or is_function(body_builder, 1)) do
      raise ArgumentError,
            "RateLimit :json_body_builder must be a 1-arity function or nil (got #{inspect(body_builder)})"
    end

    %{
      bucket: bucket,
      subject: subject,
      limit: limit,
      window: window,
      response_mode: response_mode,
      html_redirect_to: Keyword.get(opts, :html_redirect_to, @default_html_redirect),
      html_flash_template: Keyword.get(opts, :html_flash_template, @default_html_flash),
      json_body_builder: body_builder
    }
  end

  @impl true
  def call(conn, %{bucket: bucket, subject: subject_kind} = config) do
    subject_key = derive_subject_key(conn, subject_kind)
    opts = build_opts(config)
    {limit, window} = RateLimiter.resolve_bucket(bucket, opts)

    case RateLimiter.check_and_record(bucket, subject_key, opts) do
      :ok ->
        put_rate_limit_headers(conn, limit, remaining(bucket, subject_key, limit, window), window)

      {:error, retry_after} ->
        emit_denied(conn, bucket, subject_key, retry_after)

        conn
        |> put_rate_limit_headers(limit, 0, window)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> respond_denied(retry_after, config)
        |> halt()
    end
  end

  ## Response builders

  defp respond_denied(conn, retry_after, config) do
    case resolve_mode(conn, config.response_mode) do
      :html ->
        message = render_flash(config.html_flash_template, retry_after)
        target = resolve_redirect(config.html_redirect_to)

        conn
        |> maybe_put_flash(:error, message)
        |> put_resp_header("location", target)
        |> send_resp(303, "")

      :json ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, json_body(config.json_body_builder, retry_after))
    end
  end

  defp json_body(nil, retry_after), do: default_json_body(retry_after)

  defp json_body(builder, retry_after) when is_function(builder, 1) do
    builder.(retry_after)
  rescue
    e ->
      require Logger

      Logger.warning("RateLimit :json_body_builder raised: #{Exception.message(e)}")
      default_json_body(retry_after)
  end

  defp default_json_body(retry_after), do: ~s({"error":"rate_limited","retry_after":#{retry_after}})

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

  defp render_flash(template, retry_after) do
    String.replace(template, "{retry_after}", Integer.to_string(retry_after))
  end

  defp resolve_redirect(fun) when is_function(fun, 0), do: fun.()
  defp resolve_redirect(path) when is_binary(path), do: path

  defp maybe_put_flash(conn, key, message) do
    # Phoenix.Controller.put_flash/3 requires the flash to be fetched
    # (Phoenix 1.8 stores it in conn.assigns.flash). For pipelines that
    # set up flash we put it; otherwise we no-op so the plug doesn't
    # crash on JSON-shape conns lacking flash.
    if Map.has_key?(conn.assigns, :flash) do
      Phoenix.Controller.put_flash(conn, key, message)
    else
      conn
    end
  end

  defp emit_denied(conn, bucket, subject_key, retry_after) do
    Events.record(%{
      kind: :rate_limit_denied,
      severity: :warning,
      ip: client_ip(conn),
      route: conn.request_path,
      actor_id: current_actor_id_for_event(conn),
      details: %{
        "bucket" => to_string(bucket),
        "subject_key" => inspect(subject_key),
        "retry_after_seconds" => retry_after,
        "method" => conn.method
      }
    })
  rescue
    # Never let event recording break the request path.
    _ -> :ok
  end

  defp current_actor_id_for_event(conn) do
    case current_actor_id(conn) do
      nil -> nil
      id when is_binary(id) -> id
      other -> inspect(other)
    end
  end

  ## Subject key derivation

  defp derive_subject_key(conn, :ip), do: client_ip(conn)

  defp derive_subject_key(conn, :ip_and_actor) do
    {client_ip(conn), current_actor_id(conn) || :anonymous}
  end

  # Centralized extraction: honors x-forwarded-for only from trusted
  # proxies (see ServiceRadarWebNG.ClientIP), so audit/rate-limit keys
  # cannot be spoofed by untrusted clients.
  defp client_ip(conn), do: ClientIP.get(conn)

  defp current_actor_id(conn) do
    case conn.assigns do
      %{current_user: %{id: id}} -> id
      %{current_scope: %{user: %{id: id}}} -> id
      _ -> nil
    end
  end

  ## Header helpers

  defp put_rate_limit_headers(conn, limit, remaining, window) do
    reset_at = System.system_time(:second) + window

    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(0, remaining)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(reset_at))
  end

  defp remaining(bucket, subject_key, limit, window) do
    # check_and_record has already counted this request — the remaining
    # count below reflects the post-decrement state.
    case :ets.lookup(RateLimiter.__table__(), {bucket, subject_key}) do
      [{_, attempts}] ->
        now = System.system_time(:second)
        in_window = Enum.count(attempts, &(&1 >= now - window))
        max(0, limit - in_window)

      [] ->
        max(0, limit - 1)
    end
  end

  defp build_opts(%{limit: nil, window: nil}), do: []
  defp build_opts(%{limit: nil, window: w}), do: [window_seconds: w]
  defp build_opts(%{limit: l, window: nil}), do: [limit: l]
  defp build_opts(%{limit: l, window: w}), do: [limit: l, window_seconds: w]
end
