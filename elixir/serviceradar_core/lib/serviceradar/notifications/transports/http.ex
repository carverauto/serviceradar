defmodule ServiceRadar.Notifications.Transports.HTTP do
  @moduledoc """
  The single outbound HTTP path for every `:native` notification transport
  (design D2, D4, Security).

  Slack, Discord, and the generic webhook all do the same four things - guard the
  URL, build a request, classify the answer, and keep the credential out of the
  error - and each of them getting one of the four subtly wrong is how a
  notification system grows three different retry policies and one SSRF hole. So
  the four live here once and the transports call `post/3` plus `to_result/2`.

  ## The URL is guarded before a socket is opened

  Every operator-supplied URL passes `validate_https_public_url/2` (see
  `url_policy/0`) *first*: HTTPS only, port allowlisted, host resolving to a
  public address. A rejected URL returns `{:error, {:blocked_url, reason}}` and
  **no request is made**. `ServiceRadar.Monitoring.WebhookNotifier` - the module
  the notification platform replaces - posted to whatever string was in its
  config, which is an SSRF primitive wearing a configuration hat.

  Two related settings are part of the same guard and are not negotiable:

    * `redirect: false`. Following a redirect would send the `Authorization`
      header to a location that never passed the policy, so a destination could
      answer `302 http://169.254.169.254/...` and walk straight through the check
      that was just performed.
    * `retry: false`. Retry is the engine's bounded, Oban-backed mechanism
      (design D4). A transport that retries internally multiplies the attempt
      budget by a number nothing records.

  ## Failures are normalised to a closed atom vocabulary

  `{:error, {class, detail}}` where `class` is one of `:blocked_url`, `:timeout`,
  `:closed`, `:econnrefused`, `:nxdomain`, `:tls`, `:unknown`. Callers group by
  it, so it must stay small and must not carry per-request detail; `detail` is
  the human sentence, already scrubbed.

  ## `to_result/2` is where retry classification is decided, once

  It defers to `ServiceRadar.Notifications.Transport.result_from_http_status/2`
  for anything that produced a status - 5xx/408/429 retryable, other 4xx
  permanent - so a transport cannot invent a fourth opinion about what a 429
  means. Transport-level failures are retryable (a timeout or a reset is worth
  repeating); `:blocked_url` is permanent, because a URL that violates the egress
  policy will violate it again on every attempt and burning five attempts on it
  only delays the operator learning their configuration is wrong.

  ## Secrets

  Pass every resolved credential in `:sensitive_values`. Every error message this
  module produces is scrubbed against that list, and the request URL is never
  echoed into an error at all - only its host - because Slack and Discord
  incoming-webhook URLs carry the secret **in the path** (design, Security).

  ## Testing seam

  `:req_options` is merged last and is how a test injects `plug:` (a
  `Plug.Conn`-shaped fake destination) or `adapter:` (a
  `fun(request) -> {request, response_or_exception}` used to produce transport
  errors such as a timeout). Nothing in this module reaches the network in a
  test, and no test needs a network stub process.

  ## Purity

  Everything except the request itself is a pure function of its arguments. This
  module holds no process state, starts nothing, and logs nothing: the caller
  owns the log line, because the caller is the one that knows the delivery id and
  which values are sensitive.
  """

  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Result

  # `Palisade.OutboundURLPolicy` is the canonical home of this check and is what
  # the design names. Palisade is not (yet) a dependency of `serviceradar_core`,
  # and `ServiceRadar.Policies.OutboundURLPolicy` is the in-tree port of it -
  # same function heads, same error atoms, same `NetworkAddressPolicy` CIDR
  # table. Resolving the module once at compile time means the day palisade
  # becomes a dependency every native transport starts calling it with no code
  # change, and until then there is exactly one guard rather than none. A
  # `Code.ensure_loaded?/1` per request would be the same decision made
  # thousands of times.
  @url_policy (if Code.ensure_loaded?(Palisade.OutboundURLPolicy) do
                 Palisade.OutboundURLPolicy
               else
                 ServiceRadar.Policies.OutboundURLPolicy
               end)

  @default_timeout_ms 15_000
  @default_methods [:post, :put, :patch, :delete]

  # A `Retry-After` far in the future is a provider bug or a hostile answer; the
  # scheduler is bounded by `max_attempts` anyway, so clamp rather than trust.
  @max_retry_after_ms 3_600_000

  # Enough of the body to identify the rejection, short enough that it cannot
  # become a log-sized payload copy.
  @max_error_body_bytes 512

  @redacted "[REDACTED]"

  @type response :: %{status: integer(), headers: map(), body: term()}

  @type error_class ::
          :blocked_url | :timeout | :closed | :econnrefused | :nxdomain | :tls | :unknown

  @type outcome :: {:ok, response()} | {:error, {error_class(), term()}}

  @doc """
  The module that enforces the outbound URL policy.

  Exposed so a transport's docs and tests can name the guard they rely on rather
  than restating its rules.
  """
  @spec url_policy() :: module()
  def url_policy, do: @url_policy

  @doc """
  POSTs `body` to `url` after the URL passes the outbound policy.

  ## Options

    * `:headers` - a map or keyword/tuple list of request headers. Names are
      downcased; nil values are dropped.
    * `:auth` - `{:bearer, token}`, `{:basic, username, password}`,
      `{:header, name, value}`, or `nil`. Rendered into a header here so no
      caller hand-rolls `Base.encode64/1`.
    * `:content_type` - `:json` (default), `:form`, or `:text`.
    * `:timeout_ms` - connect and receive timeout, default
      `#{@default_timeout_ms}`.
    * `:allowed_ports` - forwarded to the URL policy. Omit for the default
      allowlist (`[443]`).
    * `:sensitive_values` - strings scrubbed from every error this call can
      return. Pass every resolved secret.
    * `:req_options` - merged last. The test seam; see the moduledoc.

  Returns `{:ok, %{status:, headers:, body:}}` for any answer that carried a
  status - including a 500, which is an answer - and `{:error, {class, detail}}`
  when no status came back. `headers` maps a downcased header name to its list
  of values; use `header/2` to read one.
  """
  @spec post(String.t(), term(), keyword()) :: outcome()
  def post(url, body, opts \\ []), do: request(:post, url, body, opts)

  @doc """
  Like `post/3` for the other body-carrying methods.

  `method` is one of `#{inspect(@default_methods)}`. The generic webhook
  transport lets an operator choose, because a webhook receiver that wants `PUT`
  is common enough that forcing `POST` would be a reason to reach for a plugin.
  """
  # `url` is `term()` rather than `String.t()` because the guard clause below is
  # load-bearing: a transport must classify a nonsense URL, not raise on it.
  @spec request(atom(), term(), term(), keyword()) :: outcome()
  def request(method, url, body, opts \\ [])

  def request(method, url, body, opts)
      when is_atom(method) and is_binary(url) and is_list(opts) do
    sensitive = sensitive_values(opts)

    with :ok <- validate_method(method),
         {:ok, uri} <- validate_url(url, opts) do
      run(method, uri, body, opts, sensitive)
    end
  end

  def request(_method, url, _body, _opts) do
    {:error, {:blocked_url, "expected an https URL string, got #{inspect(url)}"}}
  end

  @doc """
  Maps the outcome of `post/3` or `request/4` onto a `Transport.Result`.

  Status classification is delegated to
  `Transport.result_from_http_status/2` so all four native transports agree on
  what a 429 means. `opts` is passed through to the `Result` constructors, so a
  caller supplies `:external_correlation_id` (the provider-side handle it just
  parsed out of a 2xx body), `:result_summary`, and `:provider_metadata` here.

  A `retry-after` header on a retryable status becomes `:retry_after_ms`, clamped
  to one hour. The scheduler MAY honour it and is still bound by `max_attempts`.
  """
  @spec to_result(outcome(), keyword()) :: Result.t()
  def to_result(outcome, opts \\ [])

  def to_result({:ok, %{status: status} = response}, opts) do
    sensitive = sensitive_values(opts)

    opts
    |> Keyword.delete(:sensitive_values)
    |> Keyword.update(
      :result_summary,
      %{"http_status" => status},
      &Map.put(&1, "http_status", status)
    )
    |> put_retry_after(response, status)
    |> put_error_message(response, status, sensitive)
    |> then(&Transport.result_from_http_status(status, &1))
  end

  # A name that would not resolve is the one policy rejection that is not a
  # configuration mistake. Treating it like the others would let a resolver blink
  # and discard a page terminally, so it is classified with the other transient
  # network failures instead.
  def to_result({:error, {:blocked_url, :dns_resolution_failed}}, opts) do
    Result.retryable_failure("dns_resolution_failed",
      error_message: "the destination host could not be resolved",
      result_summary: Keyword.get(opts, :result_summary, %{}),
      provider_metadata: Keyword.get(opts, :provider_metadata, %{})
    )
  end

  def to_result({:error, {:blocked_url, detail}}, opts) do
    Result.permanent_failure("blocked_url",
      error_message: "outbound URL rejected by policy: #{scrub(detail, sensitive_values(opts))}",
      result_summary: Keyword.get(opts, :result_summary, %{}),
      provider_metadata: Keyword.get(opts, :provider_metadata, %{})
    )
  end

  def to_result({:error, {class, detail}}, opts) when is_atom(class) do
    Result.retryable_failure(Atom.to_string(class),
      error_message: scrub(detail, sensitive_values(opts)),
      result_summary: Keyword.get(opts, :result_summary, %{}),
      provider_metadata: Keyword.get(opts, :provider_metadata, %{})
    )
  end

  @doc """
  The first value of a response header, or nil.

  Accepts either the response map or its `headers` map, and is case-insensitive.
  """
  @spec header(response() | map(), String.t()) :: String.t() | nil
  def header(%{headers: headers}, name), do: header(headers, name)

  def header(headers, name) when is_map(headers) and is_binary(name) do
    case Map.get(headers, String.downcase(name)) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  def header(_headers, _name), do: nil

  @doc """
  Replaces every sensitive value inside `term` with `#{@redacted}`.

  Walks maps, lists, and tuples so a scrubbed value cannot survive by being
  nested. Every non-empty value explicitly supplied as sensitive is replaced,
  including short passwords and API keys.
  """
  @spec scrub(term(), [String.t()]) :: term()
  def scrub(term, sensitive_values), do: do_scrub(term, normalize_sensitive(sensitive_values))

  @doc """
  The `:sensitive_values` option, normalised: binaries only, deduplicated, and
  empty values dropped.
  """
  @spec sensitive_values(keyword()) :: [String.t()]
  def sensitive_values(opts) when is_list(opts) do
    opts
    |> Keyword.get(:sensitive_values, [])
    |> normalize_sensitive()
  end

  def sensitive_values(_opts), do: []

  defp normalize_sensitive(values) do
    values
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
    |> Enum.uniq()
  end

  defp do_scrub(term, []), do: term

  defp do_scrub(term, sensitive) when is_binary(term) do
    Enum.reduce(sensitive, term, &String.replace(&2, &1, @redacted))
  end

  defp do_scrub(term, sensitive) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {key, do_scrub(value, sensitive)} end)
  end

  defp do_scrub(term, sensitive) when is_list(term) do
    Enum.map(term, &do_scrub(&1, sensitive))
  end

  defp do_scrub(term, sensitive) when is_tuple(term) do
    term |> Tuple.to_list() |> do_scrub(sensitive) |> List.to_tuple()
  end

  # An atom or a number cannot contain a secret, but `inspect/1`-ing it and
  # scrubbing would turn `:ok` into a string.
  defp do_scrub(term, _sensitive) when is_atom(term) or is_number(term), do: term

  defp do_scrub(term, sensitive), do: term |> inspect() |> do_scrub(sensitive)

  # --- request --------------------------------------------------------------

  defp validate_method(method) when method in @default_methods, do: :ok

  defp validate_method(method) do
    {:error, {:blocked_url, "unsupported HTTP method #{inspect(method)}"}}
  end

  defp validate_url(url, opts) do
    policy_opts =
      case Keyword.fetch(opts, :allowed_ports) do
        {:ok, ports} -> [allowed_ports: ports]
        :error -> []
      end

    case @url_policy.validate_https_public_url(url, policy_opts) do
      {:ok, uri} -> {:ok, uri}
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  defp run(method, uri, body, opts, sensitive) do
    options = req_options(method, uri, body, opts)

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           headers: normalize_headers(response.headers),
           body: response.body
         }}

      {:error, exception} ->
        {:error, normalize_failure(exception, uri, sensitive)}
    end
  rescue
    exception -> {:error, normalize_failure(exception, uri, sensitive)}
  catch
    :exit, reason -> {:error, {:unknown, describe_exit(reason, uri, sensitive)}}
  end

  defp req_options(method, uri, body, opts) do
    timeout = timeout_ms(opts)

    [
      method: method,
      url: URI.to_string(uri),
      headers: request_headers(opts),
      # Non-negotiable; see the moduledoc.
      redirect: false,
      retry: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout]
    ]
    |> Keyword.merge(body_option(body, Keyword.get(opts, :content_type, :json)))
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> @default_timeout_ms
    end
  end

  defp body_option(body, :json), do: [json: body]
  defp body_option(body, :form), do: [form: body]
  defp body_option(body, :text) when is_binary(body), do: [body: body]
  defp body_option(body, :text), do: [body: to_string(body)]
  defp body_option(body, _other), do: [json: body]

  defp request_headers(opts) do
    opts
    |> Keyword.get(:headers, %{})
    |> normalize_request_headers()
    |> merge_auth_header(Keyword.get(opts, :auth))
  end

  defp normalize_request_headers(headers) when is_map(headers) and not is_struct(headers) do
    headers
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  end

  defp normalize_request_headers(headers) when is_list(headers) do
    headers
    |> Enum.reject(fn
      {_name, value} -> is_nil(value)
      _other -> true
    end)
    |> Map.new(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  end

  defp normalize_request_headers(_headers), do: %{}

  defp merge_auth_header(headers, nil), do: headers

  defp merge_auth_header(headers, {:bearer, token}) when is_binary(token) do
    Map.put(headers, "authorization", "Bearer " <> token)
  end

  defp merge_auth_header(headers, {:basic, username, password})
       when is_binary(username) and is_binary(password) do
    Map.put(headers, "authorization", "Basic " <> Base.encode64(username <> ":" <> password))
  end

  defp merge_auth_header(headers, {:header, name, value})
       when is_binary(name) and is_binary(value) do
    Map.put(headers, String.downcase(name), value)
  end

  defp merge_auth_header(headers, _auth), do: headers

  defp normalize_headers(headers) when is_map(headers) and not is_struct(headers) do
    Map.new(headers, fn {name, value} ->
      {String.downcase(to_string(name)), value |> List.wrap() |> Enum.map(&to_string/1)}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {name, value}, acc ->
        key = String.downcase(to_string(name))
        Map.update(acc, key, [to_string(value)], &(&1 ++ [to_string(value)]))

      _other, acc ->
        acc
    end)
  end

  defp normalize_headers(_headers), do: %{}

  # --- failure normalisation ------------------------------------------------

  defp normalize_failure(exception, uri, sensitive) do
    class = classify_reason(reason_of(exception))
    {class, describe_failure(exception, class, uri, sensitive)}
  end

  defp reason_of(%{reason: reason}), do: reason
  defp reason_of(_exception), do: nil

  defp classify_reason(:timeout), do: :timeout
  defp classify_reason(:etimedout), do: :timeout
  defp classify_reason(:closed), do: :closed
  defp classify_reason(:econnreset), do: :closed
  defp classify_reason(:econnrefused), do: :econnrefused
  defp classify_reason(:nxdomain), do: :nxdomain
  defp classify_reason({:tls_alert, _alert}), do: :tls
  defp classify_reason({:options, {:certificate, _detail}}), do: :tls
  defp classify_reason(_reason), do: :unknown

  # The URL never appears in an error: Slack and Discord incoming-webhook URLs
  # carry the credential in the path, so echoing one into a message that is
  # persisted on the delivery row would leak it past every key-name-based
  # redaction rule. The host is enough to tell an operator which destination
  # failed.
  defp describe_failure(exception, class, uri, sensitive) do
    detail =
      if is_exception(exception) do
        Exception.message(exception)
      else
        inspect(exception)
      end

    scrub("#{class} contacting #{uri.host}: #{detail}", sensitive)
  end

  defp describe_exit(reason, uri, sensitive) do
    scrub("exit contacting #{uri.host}: #{inspect(reason)}", sensitive)
  end

  # --- result derivation ----------------------------------------------------

  defp put_retry_after(opts, response, status) do
    with true <- Transport.classify_http_status(status) == :retryable_failure,
         value when is_binary(value) <- header(response, "retry-after"),
         {seconds, _rest} <- Integer.parse(String.trim(value)),
         true <- seconds >= 0 do
      Keyword.put_new(opts, :retry_after_ms, min(seconds * 1000, @max_retry_after_ms))
    else
      _other -> opts
    end
  end

  defp put_error_message(opts, response, status, sensitive) do
    if Transport.classify_http_status(status) == :delivered do
      opts
    else
      Keyword.put_new(opts, :error_message, error_message(response, status, sensitive))
    end
  end

  defp error_message(response, status, sensitive) do
    case summarize_body(response.body) do
      "" -> scrub("HTTP #{status}", sensitive)
      summary -> scrub("HTTP #{status}: #{summary}", sensitive)
    end
  end

  defp summarize_body(body) when is_binary(body), do: truncate(body)

  defp summarize_body(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> truncate(encoded)
      {:error, _reason} -> truncate(inspect(body))
    end
  end

  defp summarize_body(nil), do: ""
  defp summarize_body(body), do: truncate(inspect(body))

  defp truncate(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) > @max_error_body_bytes do
      binary_part(trimmed, 0, @max_error_body_bytes) <> "..."
    else
      trimmed
    end
  end
end
