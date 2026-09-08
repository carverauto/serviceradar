defmodule ServiceRadar.Notifications.Transports.Slack do
  @moduledoc """
  Native Slack transport (design D2, tier `:native`).

  The payload in `Transport.Request` is **already rendered** by
  `ServiceRadar.Notifications.Renderer` - Block Kit for `:slack_blocks`, a text
  field for `:markdown` / `:plain`. This module renders nothing. It resolves the
  credential, ships the bytes through
  `ServiceRadar.Notifications.Transports.HTTP`, and reports one
  `Transport.Result`.

  ## Two modes, and the choice is explicit

  `config["mode"]` is required and is one of:

    * `"incoming_webhook"` - POST the rendered payload to a Slack incoming-webhook
      URL. The URL **is** the credential: the secret sits in the URL *path*
      (`https://hooks.slack.com/services/T.../B.../<secret>`), so `config` stores
      only a `SecretRefs` reference and the plaintext URL is resolved through
      `Credentials.SecretBroker` at dispatch time.
    * `"bot_token"` - POST to `https://slack.com/api/chat.postMessage` with a
      bearer bot token and an explicit `channel`.

  ### Why `incoming_webhook` cannot run on the `:edge_agent` route

  Because the secret is in the URL path. Every credential-injection mode the
  agent supports (`http_header`, `bearer_token`, `basic_auth`, `query`,
  `form_urlencoded`, `oauth2_password_bearer`) writes a header, a query
  parameter, or a body field, and **none of them rewrites a URL path**. Handing
  the agent an already-resolved webhook URL would instead put the secret in
  `params_json`, which the security model forbids. On the control-plane route the
  problem does not arise, because the URL is resolved in Elixir and never leaves
  it.

  So `:edge_agent` + `incoming_webhook` is refused at save time by
  `validate_config/1` and again at dispatch by `deliver/2`. `bot_token` is the
  mode that works on the edge route: a bearer token is exactly what the
  `bearer_token` injection mode carries (design Security, tasks 3.2.4).

  ## HTTP 200 is not success

  Slack's Web API answers `200 OK` with `{"ok": false, "error": "..."}` for
  application-level failures - a revoked token, a channel the bot was removed
  from, a malformed block. Treating a 200 as delivered is the classic Slack
  integration bug: the delivery is recorded as sent and nobody is paged. So the
  body is parsed before the status is believed, and on a 2xx an `ok: false`
  decides the disposition:

    * `ratelimited` / `rate_limited`, `internal_error`, `service_unavailable`,
      `fatal_error`, `request_timeout`, `timeout` -> retryable, honouring
      `Retry-After`
    * everything else (`invalid_auth`, `channel_not_found`, `not_in_channel`,
      `msg_too_long`, ...) -> permanent

  An unrecognised `ok: false` error defaults to **permanent**, for the same
  reason a 400 is permanent: Slack is rejecting the request, and repeating an
  identical rejected request only delays the operator learning about it.

  On a non-2xx status the disposition always comes from
  `Transport.result_from_http_status/2`, so a 429 or a 503 means here exactly
  what it means in every other transport; the Slack error string still reaches
  `error_class` when there is one.

  ## What comes back

  `ts` becomes `external_correlation_id`. It is Slack's message handle, and it is
  what lets a later resolve update or threaded reply address the same message.

  ## Secrets and SSRF

  The outbound URL guard is not repeated here: `Transports.HTTP` validates every
  URL with the outbound URL policy it names in `HTTP.url_policy/0` (HTTPS-only,
  port-allowlisted, public-IP-only) before a socket is opened, and returns
  `{:error, {:blocked_url, _}}` with **no request made**, which `to_result/2`
  turns into a permanent failure. Duplicating the check in each transport is how
  two guards drift apart.

  Nothing here is logged - there are no `Logger` calls at all, which is the only
  reliable way to guarantee a webhook URL never reaches a log line. Resolved
  credentials are handed to `HTTP` as `sensitive_values` so its error paths scrub
  them, and `result_summary` passes through `ActionRedaction` (policy
  `northbound-action-redaction-v1`) and is then scrubbed of the resolved secret
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

  @default_api_base_url "https://slack.com/api"
  @post_message_path "/chat.postMessage"

  @modes %{"incoming_webhook" => :incoming_webhook, "bot_token" => :bot_token}
  @mode_atoms Map.values(@modes)
  @mode_names Map.keys(@modes)

  @webhook_secret "webhook_url"
  @bot_token_secret "bot_token"

  # Slack error strings worth repeating. Everything else Slack names is a
  # rejection of the request itself, and repeating it changes nothing.
  @retryable_slack_errors ~w(
    ratelimited
    rate_limited
    internal_error
    service_unavailable
    fatal_error
    request_timeout
    timeout
  )

  # Slack's documented ceiling for the top-level `text` field. Exceeding it is a
  # 400, and a 400 is terminal - a truncated page beats a lost one.
  @text_limit 40_000
  @error_message_limit 300

  @headers [{"accept", "application/json"}]

  @impl true
  def capabilities, do: [:send, :test, :rich_payload, :threading]

  @impl true
  def validate_config(config) when is_map(config) do
    config = stringify(config)

    errors =
      case mode(config) do
        {:ok, mode} ->
          mode_errors(mode, config) ++ route_errors(mode, config) ++ interactive_errors(config)

        {:error, error} ->
          [error]
      end

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

    with {:ok, mode} <- resolve_mode(config),
         :ok <- check_route(mode, request),
         {:ok, plan} <- build_plan(mode, request, config, opts) do
      post(plan, opts)
    else
      {:error, %Result{} = result} -> result
    end
  rescue
    exception -> exception_result(:error, exception)
  catch
    kind, reason -> exception_result(kind, reason)
  end

  defp resolve_mode(config) do
    case mode(config) do
      {:ok, mode} ->
        {:ok, mode}

      {:error, %{message: message}} ->
        {:error,
         Result.permanent_failure("slack_invalid_config",
           error_message: "mode " <> message,
           result_summary: %{"transport" => "slack"}
         )}
    end
  end

  # The edge route cannot carry a secret that lives in a URL path; see the
  # moduledoc. Refusing here rather than dispatching keeps the failure explicable
  # instead of turning into an agent-side 404 nobody can account for.
  defp check_route(:incoming_webhook, %Request{execution_route: :edge_agent}) do
    {:error,
     Result.permanent_failure("slack_route_unsupported",
       error_message:
         "the incoming_webhook mode cannot run on the edge_agent route because the secret " <>
           "is in the URL path and no credential-injection mode rewrites a path; use the " <>
           "bot_token mode instead",
       result_summary: %{"transport" => "slack", "mode" => "incoming_webhook"}
     )}
  end

  defp check_route(_mode, _request), do: :ok

  defp build_plan(:incoming_webhook, request, config, opts) do
    with {:ok, url} <- fetch_secret(request, config, @webhook_secret, opts),
         {:ok, body} <- build_body(request, config) do
      {:ok, plan(:incoming_webhook, url, body, nil, [url])}
    end
  end

  defp build_plan(:bot_token, request, config, opts) do
    with {:ok, token} <- fetch_secret(request, config, @bot_token_secret, opts),
         {:ok, channel} <- fetch_channel(config),
         {:ok, body} <- build_body(request, config) do
      body = body |> Map.put("channel", channel) |> put_present("thread_ts", config)

      {:ok, plan(:bot_token, post_message_url(config), body, {:bearer, token}, [token])}
    end
  end

  defp plan(mode, url, body, auth, sensitive) do
    %{
      mode: mode,
      url: url,
      body: body,
      auth: auth,
      # Normalised the same way `HTTP` normalises it, so the values this module
      # scrubs and the values `HTTP` scrubs are the same set.
      sensitive_values: HTTP.sensitive_values(sensitive_values: sensitive)
    }
  end

  defp post(plan, opts) do
    outcome =
      HTTP.post(plan.url, plan.body,
        headers: @headers,
        auth: plan.auth,
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

  defp build_body(%Request{payload_format: :slack_blocks, payload: payload}, config)
       when is_map(payload) do
    {:ok, payload |> stringify() |> put_overrides(config)}
  end

  defp build_body(%Request{payload_format: format, payload: payload}, config)
       when format in [:markdown, :plain] and is_map(payload) do
    case presence(Map.get(stringify(payload), "text")) do
      nil ->
        {:error, unsupported_payload("the rendered #{format} payload carries no text")}

      text ->
        {:ok, put_overrides(%{"text" => truncate(text, @text_limit)}, config)}
    end
  end

  defp build_body(%Request{payload_format: format}, _config) do
    {:error,
     unsupported_payload(
       "Slack accepts :slack_blocks, :markdown, and :plain payloads, got #{inspect(format)}"
     )}
  end

  defp put_overrides(body, config) do
    body |> put_present("username", config) |> put_present("icon_emoji", config)
  end

  defp unsupported_payload(message) do
    Result.permanent_failure("slack_unsupported_payload",
      error_message: message,
      result_summary: %{"transport" => "slack"}
    )
  end

  # --- response classification ----------------------------------------------

  defp result_for_response(response, plan) do
    status = status(response)
    body = decode_body(response)
    app_error = slack_error(body)
    opts = response_opts(response, body, app_error, status, plan)

    if app_error && Transport.classify_http_status(status) == :delivered do
      app_result(app_error, opts)
    else
      Transport.result_from_http_status(status, opts)
    end
  end

  defp app_result(app_error, opts) do
    error_class = Keyword.fetch!(opts, :error_class)

    if app_error in @retryable_slack_errors do
      Result.retryable_failure(error_class, opts)
    else
      Result.permanent_failure(error_class, opts)
    end
  end

  defp response_opts(response, body, app_error, status, plan) do
    ts = correlation_id(body)

    [
      external_correlation_id: ts,
      error_class: error_class(status, app_error),
      error_message: error_message(status, app_error, body, plan),
      retry_after_ms: retry_after_ms(response),
      result_summary:
        summary(plan, %{
          "http_status" => status,
          "slack_error" => app_error,
          "slack_channel" => channel_from_body(body),
          "ts" => ts
        })
    ]
  end

  defp error_class(_status, app_error) when is_binary(app_error), do: "slack_" <> app_error
  defp error_class(status, _app_error), do: "http_#{status}"

  defp error_message(status, app_error, body, plan) do
    base = "Slack responded with HTTP #{status}"

    detail =
      [app_error, body_text(body)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(": ")
      |> presence()

    case detail do
      nil ->
        base

      detail ->
        truncate(
          base <> " (" <> HTTP.scrub(detail, plan.sensitive_values) <> ")",
          @error_message_limit
        )
    end
  end

  # `ok: false` is Slack saying the request failed even when the status says 200.
  # `nil` means "no application-level error", which is not the same as success.
  defp slack_error(body) when is_map(body) do
    case {Map.get(body, "ok"), Map.get(body, "error")} do
      {false, error} when is_binary(error) -> presence(error) || "unknown_error"
      {false, _error} -> "unknown_error"
      _ok -> nil
    end
  end

  defp slack_error(_body), do: nil

  defp correlation_id(body) when is_map(body) do
    presence(Map.get(body, "ts")) || body |> Map.get("message") |> nested_ts()
  end

  defp correlation_id(_body), do: nil

  defp nested_ts(message) when is_map(message), do: presence(Map.get(stringify(message), "ts"))
  defp nested_ts(_message), do: nil

  defp channel_from_body(body) when is_map(body), do: presence(Map.get(body, "channel"))
  defp channel_from_body(_body), do: nil

  defp retry_after_ms(response) do
    response |> HTTP.header("retry-after") |> seconds_to_ms()
  end

  # --- configuration --------------------------------------------------------

  defp mode(config) do
    case Map.get(config, "mode") do
      value when value in @mode_atoms ->
        {:ok, value}

      value when is_binary(value) ->
        case Map.fetch(@modes, String.trim(value)) do
          {:ok, mode} -> {:ok, mode}
          :error -> {:error, config_error("mode", mode_message())}
        end

      nil ->
        {:error, config_error("mode", "is required; " <> mode_message())}

      _other ->
        {:error, config_error("mode", mode_message())}
    end
  end

  defp mode_message, do: "must be one of " <> Enum.join(@mode_names, ", ")

  defp mode_errors(:incoming_webhook, config) do
    secret_ref_errors(config, @webhook_secret, "a Slack incoming-webhook URL")
  end

  defp mode_errors(:bot_token, config) do
    secret_ref_errors(config, @bot_token_secret, "a Slack bot token") ++
      channel_config_errors(config) ++ api_base_url_errors(config)
  end

  # The secret must be a reference, never plaintext in `config`: `config` is
  # persisted and shown in the UI, and a webhook URL saved there is a leaked
  # credential that no amount of downstream redaction can recall.
  defp secret_ref_errors(config, field, description) do
    case Map.get(config, field) do
      value when is_binary(value) ->
        if SecretRefs.secret_ref?(String.trim(value)) do
          []
        else
          [
            config_error(
              field,
              "must be a stored credential reference; #{description} is a secret and must " <>
                "not be saved as plain text"
            )
          ]
        end

      nil ->
        [config_error(field, "is required and must be a stored credential reference")]

      _other ->
        [config_error(field, "must be a stored credential reference")]
    end
  end

  defp channel_config_errors(config) do
    case presence(Map.get(config, "channel")) do
      nil -> [config_error("channel", "is required in the bot_token mode")]
      _channel -> []
    end
  end

  defp api_base_url_errors(config) do
    case presence(Map.get(config, "api_base_url")) do
      nil ->
        []

      url ->
        case HTTP.url_policy().validate_https_public_url(url) do
          {:ok, _uri} -> []
          {:error, reason} -> [config_error("api_base_url", url_policy_message(reason))]
        end
    end
  end

  defp route_errors(:incoming_webhook, config) do
    case Map.get(config, "execution_route") do
      route when route in [:edge_agent, "edge_agent"] ->
        [
          config_error(
            "execution_route",
            "cannot be edge_agent in the incoming_webhook mode: the secret is in the URL " <>
              "path and no credential-injection mode rewrites a path; use the bot_token mode"
          )
        ]

      _route ->
        []
    end
  end

  defp route_errors(_mode, _config), do: []

  # Interactive mode is the one setting whose misconfiguration is invisible.
  # Slack does not report a missing Interactivity Request URL, an inert button
  # produces no request and no log, and a callback that cannot resolve a signing
  # secret answers 401 to a click nobody sees fail. So the parts we CAN check are
  # checked at save time, where an operator is present to read the error.
  defp interactive_errors(config) do
    if Map.get(config, "interactive") == true do
      case Map.get(config, "api_app_id") do
        value when is_binary(value) and value != "" ->
          []

        _absent ->
          [
            config_error(
              "api_app_id",
              "is required when interactive is enabled: an inbound Slack interaction names " <>
                "the app that sent it and nothing identifying this channel, so this is how " <>
                "the callback finds the signing secret to verify it"
            )
          ]
      end
    else
      []
    end
  end

  defp url_policy_message(:disallowed_scheme), do: "must use https"
  defp url_policy_message(:disallowed_port), do: "must use an allowed https port"
  defp url_policy_message(:disallowed_host), do: "must resolve to a public address"
  defp url_policy_message(:invalid_url), do: "is not a valid absolute URL"
  defp url_policy_message(reason), do: "was rejected by the outbound URL policy (#{reason})"

  defp fetch_channel(config) do
    case presence(Map.get(config, "channel")) do
      nil ->
        {:error,
         Result.permanent_failure("slack_invalid_config",
           error_message: "channel is required in the bot_token mode",
           result_summary: %{"transport" => "slack", "mode" => "bot_token"}
         )}

      channel ->
        {:ok, channel}
    end
  end

  defp post_message_url(config) do
    base = presence(Map.get(config, "api_base_url")) || @default_api_base_url

    String.trim_trailing(base, "/") <> @post_message_path
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
     Result.permanent_failure("slack_missing_secret",
       error_message: "no #{key} credential is configured for this Slack channel",
       result_summary: %{"transport" => "slack"}
     )}
  end

  # Retryable, not permanent: a credential store that is briefly unreachable is
  # the common case, and losing a page to a transient OpenBao blip is worse than
  # spending a bounded retry budget on a credential that really is gone.
  defp secret_unavailable(key, reason) do
    Result.retryable_failure("slack_secret_unavailable",
      error_message: "the #{key} credential could not be resolved: #{format_reason(reason)}",
      result_summary: %{"transport" => "slack"}
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
      result_summary: %{"transport" => "slack"}
    )
  end

  # A transport must never take the dispatcher down, and must never put an
  # exception message - which can carry the resolved webhook URL - into a
  # persisted field. Only the exception's module name survives.
  defp exception_result(kind, reason) do
    name = exception_name(reason)

    Result.retryable_failure("transport_exception",
      error_message: "the Slack transport raised #{kind}: #{name}",
      result_summary: %{"transport" => "slack", "exception" => name}
    )
  end

  defp exception_name(%module{}), do: inspect(module)
  defp exception_name(reason) when is_atom(reason), do: inspect(reason)
  defp exception_name({reason, _detail}) when is_atom(reason), do: inspect(reason)
  defp exception_name(_reason), do: "unknown"

  defp summary(plan, extra) do
    %{"transport" => "slack", "mode" => Atom.to_string(plan.mode)}
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
    presence(Map.get(body, "error")) || presence(Map.get(body, "message"))
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
