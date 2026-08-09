defmodule ServiceRadar.Notifications.Transports.Discord do
  @moduledoc """
  Native Discord transport (design D2, tier `:native`).

  The payload in `Transport.Request` is **already rendered** by
  `ServiceRadar.Notifications.Renderer` - an embed for `:discord_embed`, a text
  field for `:markdown` / `:plain`. This module renders nothing. It resolves the
  credential, ships the bytes through
  `ServiceRadar.Notifications.Transports.HTTP`, and reports one
  `Transport.Result`.

  ## The webhook URL is the credential

  A Discord webhook URL carries its token in the URL *path*
  (`https://discord.com/api/webhooks/<id>/<token>`), so `config` stores only a
  `SecretRefs` reference and the plaintext URL is resolved through
  `Credentials.SecretBroker` at dispatch time.

  The same constraint that binds Slack's incoming-webhook mode binds this
  transport, and for the same reason: none of the agent's credential-injection
  modes (`http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`,
  `oauth2_password_bearer`) rewrites a URL path, and handing the agent an
  already-resolved URL would put the token in `params_json`, which the security
  model forbids. So this transport cannot run on the `:edge_agent` route; that is
  refused at save time by `validate_config/1` and again at dispatch by
  `deliver/2`. On the control-plane route the URL never leaves Elixir, so the
  problem does not arise (design Security, tasks 3.2.4).

  ## 204, and why `wait` defaults to true

  A successful webhook execute answers **204 No Content with no body**, which
  leaves nothing to correlate a later interaction against. `?wait=true` makes
  Discord answer `200` with the created message object instead, and its `id`
  becomes the `external_correlation_id`. So `wait` defaults to true; set
  `config["wait"]` to `false` to trade the correlation id for a marginally
  cheaper send.

  ## `retry_after` is SECONDS, and it is fractional

  Discord's 429 body is
  `{"message": "You are being rate limited.", "retry_after": 0.75, "global": false}`.
  That number is **seconds**, and it is routinely fractional - unlike almost
  every other API, whose `Retry-After` is whole seconds. Two ways to get this
  wrong, both of which produce an immediate re-ban: reading it as milliseconds
  gives a sub-millisecond backoff, and `Integer.parse("0.75")` gives `0`. It is
  read as a float and converted with `round(seconds * 1000)`, with the
  `Retry-After` and `X-RateLimit-Reset-After` headers as fallbacks - both also in
  seconds.

  The disposition itself always comes from
  `Transport.result_from_http_status/2`, so a 429 is retryable and a 400 is
  terminal here exactly as in every other transport; only the retry *hint* is
  Discord-specific.

  ## Secrets and SSRF

  The outbound URL guard is not repeated here: `Transports.HTTP` validates every
  URL with the outbound URL policy it names in `HTTP.url_policy/0` (HTTPS-only,
  port-allowlisted, public-IP-only) before a socket is opened, and returns
  `{:error, {:blocked_url, _}}` with **no request made**, which `to_result/2`
  turns into a permanent failure. The query parameters appended here cannot
  change the scheme, host, or port that policy inspects.

  Nothing here is logged - there are no `Logger` calls at all, which is the only
  reliable way to guarantee a webhook URL never reaches a log line. The resolved
  URL is handed to `HTTP` as a `sensitive_value` so its error paths scrub it, and
  `result_summary` passes through `ActionRedaction` (policy
  `northbound-action-redaction-v1`) and is then scrubbed of the resolved URL
  before anything can persist it.

  ## Test seam

  `opts[:req_options]` is forwarded verbatim to `HTTP`, which merges it last into
  the `Req` options. `req_options: [plug: &my_plug/1]` answers from a
  `Plug.Conn`-shaped fake and `req_options: [adapter: &my_adapter/1]` produces
  transport errors such as a timeout, so no test reaches the network and the
  real URL policy still runs. `opts[:secret_broker]` replaces the credential
  broker the same way.

  See `openspec/changes/add-notification-platform/design.md` (D2, D3, D4, D9).
  """

  @behaviour ServiceRadar.Notifications.Transport

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP
  alias ServiceRadar.Plugins.SecretRefs

  @webhook_secret "webhook_url"

  # Discord's documented ceiling for `content`. Exceeding it is a 400, and a 400
  # is terminal - a truncated page beats a lost one.
  @content_limit 2000
  @error_message_limit 300

  @headers [{"accept", "application/json"}]

  @impl true
  def capabilities, do: [:send, :test, :rich_payload, :threading]

  @impl true
  def validate_config(config) when is_map(config) do
    config = stringify(config)

    errors =
      secret_ref_errors(config, @webhook_secret) ++ wait_errors(config) ++ route_errors(config)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_config(_config) do
    {:error, [config_error(nil, "expected a configuration map")]}
  end

  @impl true
  def deliver(%Request{} = request, opts), do: dispatch(request, opts)
  def deliver(_request, _opts), do: invalid_request()

  @impl true
  def test(%Request{} = request, opts), do: dispatch(%{request | is_test: true}, opts)
  def test(_request, _opts), do: invalid_request()

  # --- dispatch -------------------------------------------------------------

  defp dispatch(request, opts) do
    config = stringify(request.config)

    with :ok <- check_route(request),
         {:ok, plan} <- build_plan(request, config, opts) do
      post(plan, opts)
    else
      {:error, %Result{} = result} -> result
    end
  rescue
    exception -> exception_result(:error, exception)
  catch
    kind, reason -> exception_result(kind, reason)
  end

  # The edge route cannot carry a secret that lives in a URL path; see the
  # moduledoc. Refusing here rather than dispatching keeps the failure explicable
  # instead of turning into an agent-side 401 nobody can account for.
  defp check_route(%Request{execution_route: :edge_agent}) do
    {:error,
     Result.permanent_failure("discord_route_unsupported",
       error_message:
         "the Discord webhook transport cannot run on the edge_agent route because the " <>
           "token is in the URL path and no credential-injection mode rewrites a path",
       result_summary: %{"transport" => "discord"}
     )}
  end

  defp check_route(_request), do: :ok

  defp build_plan(request, config, opts) do
    with {:ok, url} <- fetch_secret(request, config, @webhook_secret, opts),
         {:ok, body} <- build_body(request, config) do
      final_url = with_query(url, query_params(config))

      {:ok,
       %{
         url: final_url,
         body: body,
         # Both forms are sensitive: the query-suffixed URL still contains the
         # token, and a scrubber holding only the original would miss it.
         sensitive_values: HTTP.sensitive_values(sensitive_values: [url, final_url])
       }}
    end
  end

  defp post(plan, opts) do
    outcome =
      HTTP.post(plan.url, plan.body,
        headers: @headers,
        sensitive_values: plan.sensitive_values,
        req_options: Keyword.get(opts, :req_options, [])
      )

    case outcome do
      {:ok, response} ->
        result_for_response(response, plan)

      {:error, _reason} = error ->
        HTTP.to_result(error,
          sensitive_values: plan.sensitive_values,
          result_summary: summary(plan, %{})
        )
    end
  end

  # --- payload --------------------------------------------------------------

  defp build_body(%Request{payload_format: :discord_embed, payload: payload}, config)
       when is_map(payload) do
    {:ok, payload |> stringify() |> put_overrides(config)}
  end

  defp build_body(%Request{payload_format: format, payload: payload}, config)
       when format in [:markdown, :plain] and is_map(payload) do
    case presence(Map.get(stringify(payload), "text")) do
      nil ->
        {:error, unsupported_payload("the rendered #{format} payload carries no text")}

      text ->
        {:ok, put_overrides(%{"content" => truncate(text, @content_limit)}, config)}
    end
  end

  defp build_body(%Request{payload_format: format}, _config) do
    {:error,
     unsupported_payload(
       "Discord accepts :discord_embed, :markdown, and :plain payloads, got #{inspect(format)}"
     )}
  end

  defp put_overrides(body, config) do
    body |> put_present("username", config) |> put_present("avatar_url", config)
  end

  defp unsupported_payload(message) do
    Result.permanent_failure("discord_unsupported_payload",
      error_message: message,
      result_summary: %{"transport" => "discord"}
    )
  end

  # --- response classification ----------------------------------------------

  defp result_for_response(response, plan) do
    status = status(response)
    body = decode_body(response)
    message_id = correlation_id(body)

    Transport.result_from_http_status(status,
      external_correlation_id: message_id,
      error_message: error_message(status, body, plan),
      retry_after_ms: retry_after_ms(response, body),
      result_summary:
        summary(plan, %{
          "http_status" => status,
          "message_id" => message_id,
          "discord_code" => discord_code(body)
        })
    )
  end

  # 204 No Content is the documented success without `?wait=true`: no body, and
  # therefore no message id to correlate a later interaction against.
  defp correlation_id(body) when is_map(body) do
    case Map.get(body, "id") do
      id when is_binary(id) -> presence(id)
      id when is_integer(id) -> Integer.to_string(id)
      _other -> nil
    end
  end

  defp correlation_id(_body), do: nil

  defp discord_code(body) when is_map(body) do
    case Map.get(body, "code") do
      code when is_integer(code) -> code
      _other -> nil
    end
  end

  defp discord_code(_body), do: nil

  defp error_message(status, body, plan) do
    base = "Discord responded with HTTP #{status}"

    case body_text(body) do
      nil ->
        base

      detail ->
        truncate(
          base <> " (" <> HTTP.scrub(detail, plan.sensitive_values) <> ")",
          @error_message_limit
        )
    end
  end

  # Seconds, fractional. The body wins over the headers because it is the value
  # Discord computed for this specific rate-limit bucket.
  defp retry_after_ms(response, body) do
    body_retry_after(body) || seconds_to_ms(HTTP.header(response, "retry-after")) ||
      seconds_to_ms(HTTP.header(response, "x-ratelimit-reset-after"))
  end

  defp body_retry_after(body) when is_map(body), do: seconds_to_ms(Map.get(body, "retry_after"))
  defp body_retry_after(_body), do: nil

  # --- configuration --------------------------------------------------------

  # The secret must be a reference, never plaintext in `config`: `config` is
  # persisted and shown in the UI, and a webhook URL saved there is a leaked
  # credential that no amount of downstream redaction can recall.
  defp secret_ref_errors(config, field) do
    case Map.get(config, field) do
      value when is_binary(value) ->
        if SecretRefs.secret_ref?(String.trim(value)) do
          []
        else
          [
            config_error(
              field,
              "must be a stored credential reference; a Discord webhook URL carries its " <>
                "token in the path and must not be saved as plain text"
            )
          ]
        end

      nil ->
        [config_error(field, "is required and must be a stored credential reference")]

      _other ->
        [config_error(field, "must be a stored credential reference")]
    end
  end

  defp wait_errors(config) do
    case Map.get(config, "wait") do
      value when value in [nil, true, false, "true", "false"] -> []
      _other -> [config_error("wait", "must be true or false")]
    end
  end

  defp route_errors(config) do
    case Map.get(config, "execution_route") do
      route when route in [:edge_agent, "edge_agent"] ->
        [
          config_error(
            "execution_route",
            "cannot be edge_agent: a Discord webhook carries its token in the URL path and " <>
              "no credential-injection mode rewrites a path"
          )
        ]

      _route ->
        []
    end
  end

  defp query_params(config) do
    wait = if wait?(config), do: [{"wait", "true"}], else: []

    case presence(Map.get(config, "thread_id")) do
      nil -> wait
      thread_id -> wait ++ [{"thread_id", thread_id}]
    end
  end

  defp wait?(config) do
    case Map.get(config, "wait") do
      false -> false
      "false" -> false
      _other -> true
    end
  end

  defp with_query(url, []), do: url

  defp with_query(url, params) do
    uri = URI.parse(url)
    merged = Enum.into(params, URI.decode_query(uri.query || ""))

    URI.to_string(%{uri | query: URI.encode_query(merged)})
  end

  # --- credentials ----------------------------------------------------------

  # `Request.secrets` is what the dispatcher already resolved; `config` carries
  # the reference for callers that hand the transport an unresolved channel.
  # Either way the plaintext arrives through `SecretBroker`, never `Vault`.
  defp fetch_secret(request, config, key, opts) do
    secrets = stringify(request.secrets)

    case presence(Map.get(secrets, key)) do
      nil -> resolve_secret_ref(Map.get(config, key), key, request, opts)
      value -> {:ok, value}
    end
  end

  defp resolve_secret_ref(ref, key, request, opts) when is_binary(ref) do
    broker = Keyword.get(opts, :secret_broker, SecretBroker)

    with {:ok, secret_id} <- SecretRefs.network_credential_ref_id(String.trim(ref)),
         {:ok, resolved} <-
           broker.resolve_network_credential_secret(secret_id, broker_opts(request, opts)),
         value when is_binary(value) <- presence(Map.get(resolved, :value)) do
      {:ok, value}
    else
      {:error, reason} -> {:error, secret_unavailable(key, reason)}
      _empty -> {:error, secret_unavailable(key, :empty_secret_payload)}
    end
  end

  defp resolve_secret_ref(_ref, key, _request, _opts) do
    {:error,
     Result.permanent_failure("discord_missing_secret",
       error_message: "no #{key} credential is configured for this Discord channel",
       result_summary: %{"transport" => "discord"}
     )}
  end

  # Retryable, not permanent: a credential store that is briefly unreachable is
  # the common case, and losing a page to a transient OpenBao blip is worse than
  # spending a bounded retry budget on a credential that really is gone.
  defp secret_unavailable(key, reason) do
    Result.retryable_failure("discord_secret_unavailable",
      error_message: "the #{key} credential could not be resolved: #{format_reason(reason)}",
      result_summary: %{"transport" => "discord"}
    )
  end

  defp broker_opts(request, opts) do
    Keyword.merge(
      [
        allow_external_resolution?: true,
        resolution_location: :control_plane,
        consumer_kind: :northbound_action,
        consumer_id: request.channel_id,
        purpose: "notification_delivery"
      ],
      Keyword.get(opts, :broker_opts, [])
    )
  end

  # --- results --------------------------------------------------------------

  defp invalid_request do
    Result.permanent_failure("invalid_request",
      error_message: "expected a %Transport.Request{}",
      result_summary: %{"transport" => "discord"}
    )
  end

  # A transport must never take the dispatcher down, and must never put an
  # exception message - which can carry the resolved webhook URL - into a
  # persisted field. Only the exception's module name survives.
  defp exception_result(kind, reason) do
    name = exception_name(reason)

    Result.retryable_failure("transport_exception",
      error_message: "the Discord transport raised #{kind}: #{name}",
      result_summary: %{"transport" => "discord", "exception" => name}
    )
  end

  defp exception_name(%module{}), do: inspect(module)
  defp exception_name(reason) when is_atom(reason), do: inspect(reason)
  defp exception_name({reason, _detail}) when is_atom(reason), do: inspect(reason)
  defp exception_name(_reason), do: "unknown"

  defp summary(plan, extra) do
    %{"transport" => "discord"}
    |> Map.merge(extra)
    |> compact()
    |> ActionRedaction.redact()
    |> HTTP.scrub(plan.sensitive_values)
  end

  defp config_error(field, message), do: %{field: field, message: message}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: inspect(reason)

  defp format_reason({reason, detail}) when is_atom(reason) and is_atom(detail),
    do: "#{inspect(reason)} (#{inspect(detail)})"

  defp format_reason({reason, _detail}) when is_atom(reason), do: inspect(reason)
  defp format_reason(_reason), do: "unknown_error"

  # --- response helpers -----------------------------------------------------

  defp status(%{status: status}) when is_integer(status), do: status
  defp status(_response), do: 0

  defp decode_body(%{body: body}) when is_map(body), do: stringify(body)

  defp decode_body(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> stringify(decoded)
      _other -> body
    end
  end

  defp decode_body(_response), do: nil

  defp body_text(body) when is_binary(body), do: presence(body)

  defp body_text(body) when is_map(body) do
    presence(Map.get(body, "message")) || presence(Map.get(body, "error"))
  end

  defp body_text(_body), do: nil

  defp seconds_to_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {seconds, _rest} when seconds >= 0 -> round(seconds * 1000)
      _other -> nil
    end
  end

  defp seconds_to_ms(value) when is_number(value) and value >= 0, do: round(value * 1000)
  defp seconds_to_ms(_value), do: nil

  # --- small helpers --------------------------------------------------------

  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), value} end)
  end

  defp stringify(_value), do: %{}

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: inspect(key)

  defp put_present(map, key, config) do
    case presence(Map.get(config, key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) <= limit, do: value, else: String.slice(value, 0, limit)
  end

  defp truncate(value, _limit), do: value
end
