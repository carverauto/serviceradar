defmodule Palisade.Plug.RateLimit do
  @moduledoc """
  Rate-limits requests in a named bucket through a `Palisade.RateLimit`
  backend.

      plug Palisade.Plug.RateLimit,
        bucket: :login,
        limit: 5,
        window_ms: 60_000,
        client_ip: [trusted_proxies: ["10.0.0.0/8"]]

  Each bucket counts separately: the backend key is `{bucket, subject}`,
  where the subject is the client address or the result of `:key`. One
  client exhausting a bucket does not affect other clients or other buckets.

  Every response that passes through gets `x-ratelimit-limit`,
  `x-ratelimit-remaining` and `x-ratelimit-reset` (Unix time, in seconds,
  at which the current window ends). A denied request is halted with 429
  and a `retry-after` header in whole seconds.

  ## Options

    * `:bucket` - required. Any term naming the bucket.
    * `:limit` - required. Requests allowed per window.
    * `:window_ms` - required. Window length in milliseconds.
    * `:key` - `:ip` (default) or a 1-arity function of the conn returning
      the subject, for example `{client_ip, user_id}`. A function returning
      `nil` falls back to the client address.
    * `:client_ip` - options for `Palisade.ClientIP`, used to resolve the
      client address. Not needed when `Palisade.Plug.RemoteIP` runs first.
    * `:backend` - a module or `{module, opts}`. Default
      `{Palisade.RateLimit.ETS, []}`, which needs the default
      `Palisade.RateLimit.ETS` process running.
    * `:response` - `:auto` (default), `:json` or `:html`. `:auto` answers
      HTML when the `accept` header names `text/html`, JSON otherwise.
    * `:on_deny` - a 2-arity function `(conn, retry_after_seconds) -> conn`
      that builds the denied response instead of the default 429 body. The
      rate-limit and `retry-after` headers are already set, and the plug
      halts the returned conn. If it returns a conn that was not sent, the
      default 429 is sent.

  The default JSON body is `{"error":"rate_limited","retry_after":N}`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Palisade.ClientIP
  alias Palisade.RateLimit

  @impl Plug
  def init(opts) do
    config = %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      window_ms: Keyword.fetch!(opts, :window_ms),
      key: Keyword.get(opts, :key, :ip),
      client_ip: ClientIP.new(Keyword.get(opts, :client_ip, [])),
      backend: backend!(Keyword.get(opts, :backend, Palisade.RateLimit.ETS)),
      response: Keyword.get(opts, :response, :auto),
      on_deny: Keyword.get(opts, :on_deny)
    }

    Enum.each(
      [:limit, :window_ms, :key, :response, :on_deny],
      &validate!(&1, Map.fetch!(config, &1))
    )

    config
  end

  defp validate!(key, value) do
    valid? =
      case key do
        positive when positive in [:limit, :window_ms] -> is_integer(value) and value > 0
        :key -> value == :ip or is_function(value, 1)
        :response -> value in [:auto, :json, :html]
        :on_deny -> is_nil(value) or is_function(value, 2)
      end

    if !valid?, do: invalid!(key, value)
  end

  @impl Plug
  def call(conn, config) do
    key = {config.bucket, subject(conn, config)}

    case RateLimit.check(config.backend, key, config.limit, config.window_ms) do
      {:allow, remaining, reset_ms} ->
        put_rate_limit_headers(conn, config.limit, remaining, reset_ms)

      {:deny, retry_after_ms} ->
        retry_after = max(1, ceil_div(retry_after_ms, 1000))

        conn
        |> put_rate_limit_headers(config.limit, 0, retry_after_ms)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> deny(retry_after, config)
        |> halt()
    end
  end

  defp subject(conn, %{key: :ip} = config), do: client_ip(conn, config)

  defp subject(conn, %{key: fun} = config) do
    case fun.(conn) do
      nil -> client_ip(conn, config)
      subject -> subject
    end
  end

  defp client_ip(conn, config),
    do: conn |> ClientIP.from_conn(config.client_ip) |> ClientIP.format()

  defp deny(conn, retry_after, %{on_deny: on_deny} = config) when is_function(on_deny, 2) do
    case on_deny.(conn, retry_after) do
      %Plug.Conn{state: :unset} = conn -> default_deny(conn, retry_after, config)
      %Plug.Conn{} = conn -> conn
    end
  end

  defp deny(conn, retry_after, config), do: default_deny(conn, retry_after, config)

  defp default_deny(conn, retry_after, config) do
    if html?(conn, config.response) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(429, html_body(retry_after))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate_limited","retry_after":#{retry_after}}))
    end
  end

  defp html?(_conn, :html), do: true
  defp html?(_conn, :json), do: false

  defp html?(conn, :auto) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp html_body(retry_after) do
    "<!DOCTYPE html><html><head><title>Too Many Requests</title></head><body>" <>
      "<h1>Too Many Requests</h1><p>Please try again in #{retry_after} seconds.</p>" <>
      "</body></html>"
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset_ms) do
    reset_at = System.system_time(:second) + ceil_div(reset_ms, 1000)

    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(reset_at))
  end

  defp backend!({module, opts} = backend) when is_atom(module) and is_list(opts), do: backend
  defp backend!(module) when is_atom(module), do: {module, []}
  defp backend!(other), do: invalid!(:backend, other)

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  @spec invalid!(atom(), term()) :: no_return()
  defp invalid!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
  end
end
