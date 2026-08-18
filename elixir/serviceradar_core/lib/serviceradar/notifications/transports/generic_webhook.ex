defmodule ServiceRadar.Notifications.Transports.GenericWebhook do
  @moduledoc """
  The `:native` generic-webhook transport: POST the rendered `:json` payload to
  an operator-supplied HTTPS endpoint.

  This is the replacement for `ServiceRadar.Monitoring.WebhookNotifier`, and the
  differences are the point of the replacement rather than incidental:

  | `WebhookNotifier` | This transport |
  | --- | --- |
  | Posted to whatever string was in config | URL passes the outbound policy first (`Transports.HTTP`) |
  | `EEx.eval_string/2` on an operator template | Restricted substitution in `Notifications.Renderer` (design D9) |
  | Cooldown per webhook, inside the notifier | Dedupe, suppression, and `rate_limit_per_minute` in the engine (D1) |
  | Node/service state tracked in a GenServer | `NotificationDelivery` rows (D4) |
  | Credentials as plaintext `headers` in app config | `secret_refs` resolved through `Credentials.SecretBroker` |
  | `{:error, reason}` and a `Logger.error` | A `Transport.Result` with a retry disposition (D4/C7) |

  ## Configuration

  Stored on `NotificationChannel.config`, which is NOT a sensitive column, so it
  may hold no credential material.

  | Key | Required | Meaning |
  | --- | --- | --- |
  | `url` | yes | HTTPS endpoint. Must pass the outbound policy at save time. |
  | `method` | no | `POST` (default), `PUT`, or `PATCH`. |
  | `headers` | no | Extra request headers. Credential-shaped names are rejected. |
  | `auth_mode` | no | `none` (default), `bearer`, `basic`, or `header`. |
  | `auth_header_name` | `header` mode | Header the secret is written to, e.g. `X-API-Key`. |
  | `username` | `basic` mode | Basic-auth username; the password is a secret. |
  | `timeout_ms` | no | Connect/receive timeout, default 15000. |

  ## Secrets

  `NotificationChannel.secret_refs` names the credential; the dispatcher resolves
  it through `ServiceRadar.Plugins.SecretRefs` (which calls
  `ServiceRadar.Credentials.SecretBroker.resolve_network_credential_secret/2`)
  and hands the resolved values to this transport as `Request.secrets`:

  | `auth_mode` | `secret_refs` key | `Request.secrets` key |
  | --- | --- | --- |
  | `bearer` | `token` | `token` |
  | `header` | `token` | `token` |
  | `basic` | `password` | `password` |

  A transport never calls the broker itself. It is a pure function of its
  request, which is what lets every one of its tests run `async: true` with no
  database, and it means a broker outage produces one classified failure where
  the resolution happens instead of an unclassified failure inside each of N
  transports.

  Every resolved secret is passed to `Transports.HTTP` as `:sensitive_values`, so
  it cannot survive into an error message, and log lines pass through
  `ActionRedaction` (policy `northbound-action-redaction-v1`).

  ## Migrating an existing `WebhookNotifier` entry

      config :serviceradar_core, ServiceRadar.Monitoring.WebhookNotifier,
        webhooks: [%{url: "https://hooks.example.com/x",
                     headers: [%{key: "Authorization", value: "Bearer abc123"}],
                     cooldown: :timer.minutes(5),
                     template: nil,
                     enabled: true}]

  becomes one `NotificationChannel` on the seeded `webhook` provider:

    * `url` -> `config["url"]`.
    * `headers` -> `config["headers"]`, EXCEPT credential-bearing ones. The
      `Authorization` header above becomes `auth_mode: "bearer"` plus a
      `secret_refs["token"]`; `validate_config/1` rejects it as a plain header so
      the migration cannot quietly copy a bearer token into a non-sensitive
      column.
    * `cooldown` -> not a transport concern. Use the channel's
      `rate_limit_per_minute`, or `Notifications.Dedupe` for repeat suppression.
    * `template` (EEx) -> a `NotificationTemplate` with `payload_format: :json`.
      The default `WebhookNotifier` payload has no direct equivalent and does not
      need one: the `:json` renderer's envelope carries the same fields under
      stable names.
    * `enabled` -> `NotificationChannel.enabled`.

  ## Testing seam

  `opts[:req_options]` is forwarded to `Transports.HTTP` and is how a test
  injects `plug:` or `adapter:`. Nothing here reaches the network in a test.
  """

  @behaviour ServiceRadar.Notifications.Transport

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP

  require Logger

  @auth_modes ~w(none bearer basic header)
  @methods %{"POST" => :post, "PUT" => :put, "PATCH" => :patch}

  # RFC 7230 token. Anything outside it - notably CR and LF - is a header
  # injection attempt or a typo that would produce one.
  @header_name_regex ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  # Header names that carry credentials. They are refused in `headers` because
  # `config` is not a sensitive column; the operator uses `auth_mode` plus a
  # secret ref instead, which is the whole reason those two fields exist.
  @credential_header_fragments ~w(
    authorization
    proxy-authorization
    auth
    api-key
    apikey
    token
    secret
    password
    credential
    cookie
  )

  # Best-effort provider handles. A generic webhook has no standard for this, so
  # the transport looks in the places receivers actually use and records nothing
  # when it finds none - an absent correlation id is normal here, unlike Slack.
  @correlation_body_keys ~w(id message_id messageId correlation_id correlationId request_id requestId)
  @correlation_headers ~w(x-request-id x-message-id x-correlation-id)

  @impl true
  @spec capabilities() :: [Transport.capability()]
  def capabilities, do: [:send, :test]

  @impl true
  @spec validate_config(term()) :: :ok | {:error, [Transport.config_error()]}
  def validate_config(config) when is_map(config) do
    case url_errors(config) ++ structural_errors(config) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_config(config) do
    {:error, [%{field: nil, message: "expected a configuration map, got #{inspect(config)}"}]}
  end

  @impl true
  @spec deliver(Request.t() | term(), keyword()) :: Result.t()
  def deliver(%Request{} = request, opts) when is_list(opts) do
    config = normalize_map(request.config)
    secrets = normalize_map(request.secrets)
    sensitive = secret_values(secrets)

    with :ok <- validate_structure(config),
         {:ok, auth} <- resolve_auth(config, secrets) do
      config
      |> send_payload(request, auth, sensitive, opts)
      |> log_failure(request, sensitive)
    else
      {:error, errors} -> invalid_config(errors, request, sensitive)
    end
  rescue
    exception -> unexpected(exception, __STACKTRACE__, request)
  end

  def deliver(request, _opts) do
    Result.permanent_failure("invalid_request",
      error_message: "expected a Transport.Request, got #{inspect(request)}"
    )
  end

  @impl true
  @doc """
  Test send.

  Deliberately `deliver/2` itself: a test that took a shortcut past the URL
  guard, the credential, or the rendered payload would not be evidence that the
  channel works (design D2). The delivery it produces carries `is_test: true`, so
  the engine already excludes it from every count.
  """
  @spec test(Request.t(), keyword()) :: Result.t()
  def test(request, opts), do: deliver(request, opts)

  # --- delivery -------------------------------------------------------------

  # Deliberately NOT `validate_config/1`. That one resolves the URL's host
  # through DNS, which is right at save time and wrong per delivery: it would
  # resolve twice for every notification, and a transient resolver failure would
  # come back as a PERMANENT `invalid_config` result - discarding a page because
  # DNS blinked. The URL guard still runs before any socket is opened, inside
  # `Transports.HTTP`, where `to_result/2` classifies an unresolvable host as
  # retryable and a scheme/host/port violation as permanent.
  defp validate_structure(config) do
    case structural_errors(config) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp structural_errors(config) do
    method_errors(config) ++
      header_errors(config) ++ auth_errors(config) ++ timeout_errors(config)
  end

  defp send_payload(config, request, auth, sensitive, opts) do
    url = string(config, "url")

    http_opts = [
      headers: extra_headers(config),
      auth: auth,
      content_type: :json,
      timeout_ms: timeout_ms(config),
      sensitive_values: sensitive,
      req_options: Keyword.get(opts, :req_options, [])
    ]

    config
    |> method()
    |> HTTP.request(url, request.payload, http_opts)
    |> to_result(sensitive)
  end

  defp to_result({:ok, response} = outcome, sensitive) do
    HTTP.to_result(outcome,
      sensitive_values: sensitive,
      external_correlation_id: correlation_id(response),
      result_summary: %{"http_status" => response.status}
    )
  end

  defp to_result(outcome, sensitive), do: HTTP.to_result(outcome, sensitive_values: sensitive)

  defp correlation_id(%{status: status} = response) when status >= 200 and status < 300 do
    body_correlation_id(response.body) || header_correlation_id(response)
  end

  defp correlation_id(_response), do: nil

  defp body_correlation_id(body) when is_map(body) do
    Enum.find_value(@correlation_body_keys, fn key ->
      case Map.get(body, key) do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        _other -> nil
      end
    end)
  end

  defp body_correlation_id(_body), do: nil

  defp header_correlation_id(response) do
    Enum.find_value(@correlation_headers, fn name -> HTTP.header(response, name) end)
  end

  # --- configuration --------------------------------------------------------

  defp method(config),
    do: Map.get(@methods, String.upcase(string(config, "method") || "POST"), :post)

  defp timeout_ms(config) do
    case Map.get(config, "timeout_ms") do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> nil
    end
  end

  # Header names are downcased here, not only on the way out, so that
  # `validate_config/1` refuses `Authorization` and `authorization` identically.
  # Case-sensitive validation of a case-insensitive field is how a credential
  # ends up in a non-sensitive column despite a check that reads as if it
  # prevented exactly that.
  defp extra_headers(config) do
    case Map.get(config, "headers") do
      headers when is_map(headers) -> downcase_keys(headers)
      _other -> %{}
    end
  end

  defp downcase_keys(headers) do
    headers
    |> normalize_map()
    |> Map.new(fn {name, value} -> {String.downcase(name), value} end)
  end

  defp resolve_auth(config, secrets) do
    case auth_mode(config) do
      "none" ->
        {:ok, nil}

      "bearer" ->
        with_secret(secrets, "token", &{:bearer, &1})

      "header" ->
        with_secret(secrets, "token", &{:header, string(config, "auth_header_name"), &1})

      "basic" ->
        with_secret(secrets, "password", &{:basic, string(config, "username"), &1})
    end
  end

  defp with_secret(secrets, key, builder) do
    case Map.get(secrets, key) do
      value when is_binary(value) and value != "" ->
        {:ok, builder.(value)}

      _other ->
        {:error,
         [
           %{
             field: "secret_refs.#{key}",
             message:
               "this channel's auth_mode needs a resolved #{key} secret; check the channel's secret_refs"
           }
         ]}
    end
  end

  defp auth_mode(config) do
    case string(config, "auth_mode") do
      mode when mode in @auth_modes -> mode
      _other -> "none"
    end
  end

  # --- validation -----------------------------------------------------------

  defp url_errors(config) do
    case string(config, "url") do
      nil ->
        [%{field: "url", message: "is required"}]

      url ->
        case HTTP.url_policy().validate_https_public_url(url) do
          {:ok, _uri} -> []
          {:error, reason} -> [%{field: "url", message: url_policy_message(reason)}]
        end
    end
  end

  defp url_policy_message(:disallowed_scheme), do: "must be an https:// URL"
  defp url_policy_message(:disallowed_port), do: "must use port 443"

  defp url_policy_message(:disallowed_host) do
    "must resolve to a public address; loopback, link-local, and private hosts are refused"
  end

  defp url_policy_message(:dns_resolution_failed), do: "host could not be resolved"
  defp url_policy_message(_reason), do: "is not a usable https URL"

  defp method_errors(config) do
    case string(config, "method") do
      nil ->
        []

      method ->
        if Map.has_key?(@methods, String.upcase(method)) do
          []
        else
          [%{field: "method", message: "must be one of #{Enum.join(Map.keys(@methods), ", ")}"}]
        end
    end
  end

  defp header_errors(config) do
    case Map.get(config, "headers") do
      nil -> []
      headers when is_map(headers) -> Enum.flat_map(downcase_keys(headers), &header_error/1)
      _other -> [%{field: "headers", message: "must be a map of header name to value"}]
    end
  end

  defp header_error({name, value}) do
    cond do
      not Regex.match?(@header_name_regex, name) ->
        [%{field: "headers.#{name}", message: "is not a valid HTTP header name"}]

      credential_header?(name) ->
        [
          %{
            field: "headers.#{name}",
            message:
              "carries a credential and config is not a sensitive column; use auth_mode with a secret ref instead"
          }
        ]

      not is_binary(value) or String.contains?(value, ["\r", "\n"]) ->
        [%{field: "headers.#{name}", message: "must be a single-line string value"}]

      true ->
        []
    end
  end

  defp credential_header?(name) do
    Enum.any?(@credential_header_fragments, &String.contains?(name, &1))
  end

  defp auth_errors(config) do
    case string(config, "auth_mode") do
      nil ->
        []

      mode when mode in @auth_modes ->
        auth_mode_errors(mode, config)

      mode ->
        [
          %{
            field: "auth_mode",
            message: "must be one of #{Enum.join(@auth_modes, ", ")}, got #{mode}"
          }
        ]
    end
  end

  defp auth_mode_errors("header", config) do
    case string(config, "auth_header_name") do
      nil ->
        [%{field: "auth_header_name", message: "is required when auth_mode is header"}]

      name ->
        if Regex.match?(@header_name_regex, name) do
          []
        else
          [%{field: "auth_header_name", message: "is not a valid HTTP header name"}]
        end
    end
  end

  defp auth_mode_errors("basic", config) do
    case string(config, "username") do
      nil -> [%{field: "username", message: "is required when auth_mode is basic"}]
      _username -> []
    end
  end

  defp auth_mode_errors(_mode, _config), do: []

  defp timeout_errors(config) do
    case Map.get(config, "timeout_ms") do
      nil ->
        []

      timeout when is_integer(timeout) and timeout > 0 ->
        []

      _other ->
        [%{field: "timeout_ms", message: "must be a positive integer number of milliseconds"}]
    end
  end

  # --- failures -------------------------------------------------------------

  defp invalid_config(errors, request, sensitive) do
    result =
      Result.permanent_failure("invalid_config",
        error_message: HTTP.scrub(describe_errors(errors), sensitive),
        result_summary: %{"config_errors" => Enum.map(errors, & &1.field)}
      )

    log_failure(result, request, sensitive)
  end

  defp describe_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{field: nil, message: message} -> message
      %{field: field, message: message} -> "#{field} #{message}"
    end)
  end

  # A transport must never take the dispatcher down (design D2). Anything that
  # escapes the normal paths becomes a retryable failure with the delivery id
  # attached, which is a row an operator can read rather than an Oban stack
  # trace.
  defp unexpected(exception, stacktrace, request) do
    Logger.error(
      "generic webhook transport crashed delivery=#{inspect(request_id(request))} " <>
        Exception.format(:error, exception, stacktrace)
    )

    Result.retryable_failure("transport_exception",
      error_message: "the webhook transport raised #{inspect(exception.__struct__)}"
    )
  end

  defp log_failure(%Result{disposition: :delivered} = result, _request, _sensitive), do: result

  defp log_failure(%Result{} = result, request, sensitive) do
    context =
      %{
        "delivery_id" => request_id(request),
        "channel_id" => Map.get(request, :channel_id),
        "error_class" => result.error_class,
        "error_message" => result.error_message
      }
      |> ActionRedaction.redact()
      |> HTTP.scrub(sensitive)

    Logger.warning("generic webhook delivery failed: #{inspect(context)}")

    result
  end

  defp request_id(%Request{delivery_id: delivery_id}), do: delivery_id
  defp request_id(_request), do: nil

  # --- map access -----------------------------------------------------------

  defp string(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  # Atom keys are matched by comparing atoms already present in the map, so no
  # atom is created from operator input (Iron Laws).
  defp normalize_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp normalize_map(_map), do: %{}

  defp secret_values(secrets) do
    secrets
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end
end
