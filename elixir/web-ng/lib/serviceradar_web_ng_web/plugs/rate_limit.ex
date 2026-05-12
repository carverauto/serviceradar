defmodule ServiceRadarWebNGWeb.Plugs.RateLimit do
  @moduledoc """
  Plug that gates incoming requests through `ServiceRadar.Security.RateLimiter`.

  Pipelines opt in by specifying a named bucket; the bucket's `limit`
  and `window_seconds` come from the core config (`ServiceRadar.Security.RateLimiter`).
  On denial the plug halts the connection with HTTP 429 and sets
  `retry-after` and `x-ratelimit-{limit,remaining,reset}` headers.

  ## Options

    * `:bucket` — bucket atom, required (e.g. `:auth_local`, `:webhook_ingest`).
    * `:subject` — `:ip` (default) or `:ip_and_actor` to key the limit on
      `{ip, current_actor_id || :anonymous}` for password-spray defense.
    * `:limit`, `:window_seconds` — explicit overrides; usually unset so
      the bucket config wins.

  Place this plug after `:fetch_session` and any auth plug that puts
  the current user/actor into the conn assigns; otherwise the
  `:ip_and_actor` subject collapses to `{ip, :anonymous}`.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.RateLimiter

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    subject = Keyword.get(opts, :subject, :ip)
    limit = Keyword.get(opts, :limit)
    window = Keyword.get(opts, :window_seconds)
    %{bucket: bucket, subject: subject, limit: limit, window: window}
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
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limited","retry_after":#{retry_after}}))
        |> halt()
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

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",", parts: 2) |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> List.to_string()
    end
  end

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
