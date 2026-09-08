defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.TestSend do
  @moduledoc """
  Test-send for a channel that has not been saved yet.

  The requirement is precise: an operator fills in a provider configuration,
  types a bot token, and presses *Send test* **before** the channel exists. So
  this cannot go through the dispatcher, which starts from a persisted
  `NotificationChannel` and a `NotificationDelivery` row. It goes through the
  same transport the dispatcher would call, with the same
  `ServiceRadar.Notifications.Transport.Request` struct, the same
  `validate_config/1`, and the same `ServiceRadar.Notifications.Renderer` - a
  test that took a shortcut would not be evidence the channel works.

  Nothing about the decision engine is reimplemented here. This module resolves
  the transport, renders a synthetic notification, calls `test/2`, and reduces
  the `Transport.Result` to something the LiveView can display.

  ## The secret never round-trips through the DOM

  The in-form secret arrives once, in the submitted parameters, and is handed
  straight to `Request.secrets`. It is not written to socket assigns, not echoed
  back into the form, and not included in the returned summary: the result is
  built from `Result.result_summary` after `ActionRedaction`, and the operator's
  own typed value is added to the scrub list so a provider that echoes the
  credential back in an error string cannot put it on the page.

  ## SSRF

  Any operator-supplied outbound URL in the configuration is validated by
  `ServiceRadar.Policies.OutboundURLPolicy.validate_https_public_url/2` before a
  request is made, and the specific rejection reason is surfaced - "not HTTPS",
  "private address" - rather than a generic failure that leaves an operator
  guessing.

  ## No delivery row

  A test send from an unsaved channel writes no `NotificationChannel` and no
  `NotificationDelivery`: there is no channel id to attribute one to. Test
  deliveries recorded by the engine for a *saved* channel carry `is_test: true`
  and are rendered distinctly in the Delivery Log; this path simply produces
  none, which is why the inline result is the only record of it.
  """

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Registry
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Policies.OutboundURLPolicy

  # Persist-time `validate_config/1` requires secretRef fields to be stored
  # references. A test send that just received plaintext in `secrets` has no
  # reference yet; this stand-in satisfies that contract without putting the
  # typed secret back into `config`.
  @test_send_secret_ref "secretref:test-send:pending"

  @redaction_policy "northbound-action-redaction-v1"

  @subject "ServiceRadar test notification"
  @body "This is a test notification from ServiceRadar. If you can read it, this channel configuration can deliver a page."

  # Config keys that carry an operator-supplied outbound URL. A key not listed
  # here is not silently trusted: it is simply not a URL field in any first-party
  # provider schema, and a schema that adds one declares `format: "uri"`, which
  # `url_values/2` also picks up.
  @url_keys ~w(url webhook_url api_base_url endpoint)

  @type outcome :: %{
          status: :ok | :error,
          headline: String.t(),
          detail: String.t() | nil,
          error_class: String.t() | nil,
          summary: [{String.t(), String.t()}]
        }

  @doc """
  Runs a test send against the in-form configuration.

  `provider` is the selected `NotificationProvider`; `config` is the
  non-secret configuration map; `secrets` maps each `secretRef` property name to
  the plaintext the operator just typed.
  """
  @spec run(term(), map(), map(), keyword()) :: {:ok, outcome()} | {:error, outcome()}
  def run(provider, config, secrets, opts \\ []) do
    with {:ok, module} <- transport_module(provider),
         :ok <- validate_urls(config, secrets, opts),
         :ok <- validate_config(module, config, secrets),
         {:ok, rendered} <- render(provider) do
      request = request(provider, config, secrets, rendered)

      request
      |> module.test(Keyword.get(opts, :transport_opts, []))
      |> outcome(Map.values(secrets))
    else
      {:error, %{status: :error} = outcome} -> {:error, outcome}
    end
  end

  # --- transport resolution --------------------------------------------------

  # Only the `:native` tier is dispatchable from the control plane without a
  # persisted channel today. A `:declarative` or `:wasm_plugin` provider is
  # refused with the reason rather than silently reporting success, because a
  # test that cannot run is not a passing test.
  defp transport_module(%{provider_type: :native, implementation_module: module}) when is_binary(module) do
    case Registry.resolve(module) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error, failure("Provider transport unavailable", Registry.describe_error(reason))}
    end
  end

  defp transport_module(%{provider_type: type}) do
    {:error,
     failure(
       "Test send is not available for this provider yet",
       "#{inspect(type)} providers are dispatched through the plugin host, which needs a saved channel. Save the channel first, then test it."
     )}
  end

  defp transport_module(_provider) do
    {:error, failure("Select a provider first", "A test send needs a provider to dispatch through.")}
  end

  # --- validation ------------------------------------------------------------

  defp validate_urls(config, secrets, opts) do
    (url_values(config) ++ url_values(secrets))
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {key, url}, :ok ->
      case OutboundURLPolicy.validate_https_public_url(url, Keyword.get(opts, :url_policy, [])) do
        {:ok, _uri} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            failure(
              "Outbound URL refused",
              "#{key}: #{url_rejection(reason)}"
            )}}
      end
    end)
  end

  defp url_values(map) when is_map(map) do
    map
    |> Enum.filter(fn {key, value} ->
      is_binary(value) and String.trim(value) != "" and to_string(key) in @url_keys and
        not SecretRefs.secret_ref?(String.trim(value))
    end)
    |> Enum.map(fn {key, value} -> {to_string(key), String.trim(value)} end)
  end

  defp url_values(_map), do: []

  # These heads must match the atoms the policy ACTUALLY returns. The full surface is
  # `:invalid_url`, `:disallowed_scheme`, `:disallowed_port` from
  # ServiceRadar.Policies.OutboundURLPolicy, plus `:disallowed_host`,
  # `:dns_resolution_failed` and `:invalid_cidr` passed through from
  # ServiceRadar.Policies.NetworkAddressPolicy. An earlier version of this function
  # named four atoms nobody returns (`:scheme_not_allowed`, `:port_not_allowed`,
  # `:host_not_allowed`, `:private_address`), so every scheme, port and host refusal
  # fell through to the generic clause - defeating the whole point of this function,
  # which is to tell an operator WHICH rule refused their URL instead of leaving them
  # guessing. If you add a reason to either policy, add it here too.
  defp url_rejection(:invalid_url), do: "the value is not a URL"
  defp url_rejection(:disallowed_scheme), do: "only https:// URLs are allowed"
  defp url_rejection(:disallowed_port), do: "the port is not allowed"

  defp url_rejection(:disallowed_host),
    do: "the host is not allowed (loopback, link-local, and private addresses are refused)"

  defp url_rejection(:dns_resolution_failed), do: "the host name could not be resolved"
  defp url_rejection(:invalid_cidr), do: "the configured address policy is invalid"
  defp url_rejection(reason), do: "rejected by the outbound URL policy (#{inspect(reason)})"

  defp validate_config(module, config, secrets) do
    case module.validate_config(config_for_validation(config, secrets)) do
      :ok -> :ok
      {:error, errors} -> {:error, failure("Configuration is not valid", config_errors(errors))}
    end
  end

  defp config_for_validation(config, secrets) when is_map(config) and is_map(secrets) do
    Enum.reduce(secrets, stringify_keys(config), fn {key, value}, acc ->
      field = to_string(key)

      if present_secret?(value) and not present_secret?(Map.get(acc, field)) do
        Map.put(acc, field, @test_send_secret_ref)
      else
        acc
      end
    end)
  end

  defp config_for_validation(config, _secrets), do: config

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present_secret?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_secret?(_value), do: false

  defp config_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", &config_error/1)
  end

  defp config_errors(other), do: inspect(other)

  defp config_error(%{field: nil, message: message}), do: message
  defp config_error(%{field: field, message: message}), do: "#{field}: #{message}"
  defp config_error(%{"field" => field, "message" => message}), do: "#{field}: #{message}"
  defp config_error(other), do: inspect(other)

  # --- rendering -------------------------------------------------------------

  defp render(provider) do
    formats = Map.get(provider, :payload_formats) || []

    template = %{subject_template: @subject, body_template: body_template()}

    case Renderer.render(sample_alert(), template, nil,
           supported_formats: formats,
           provider_version: Map.get(provider, :definition_version),
           include_action_links?: false,
           links: test_links()
         ) do
      {:ok, rendered} ->
        {:ok, rendered}

      {:error, reason} ->
        {:error, failure("The test notification could not be rendered", Renderer.describe_error(reason))}
    end
  end

  # A synthetic snapshot, clearly labelled. It is never attributed to a real
  # alert, so nothing here can be mistaken for one in a destination's history.
  defp sample_alert do
    %{
      "id" => "00000000-0000-0000-0000-000000000000",
      "title" => @subject,
      "description" => @body,
      "severity" => "info",
      "alert_class" => "notification_test",
      "source" => "serviceradar",
      "is_test" => true
    }
  end

  defp body_template do
    case public_base_url() do
      nil -> @body
      base -> @body <> " Open ServiceRadar: #{base}/alerts"
    end
  end

  defp test_links do
    case public_base_url() do
      nil -> %{}
      base -> %{"alert" => base <> "/alerts"}
    end
  end

  defp public_base_url do
    env = System.get_env("SERVICERADAR_NOTIFICATION_ACTION_BASE_URL")

    if is_binary(env) and String.trim(env) != "" do
      env |> String.trim() |> String.trim_trailing("/")
    else
      endpoint_public_base_url()
    end
  end

  # Endpoint.url/0 reads persistent_term and raises when the endpoint is not
  # started. db_free CI (`unit_tests_phoenix_live`) runs with --no-start.
  defp endpoint_public_base_url do
    case ServiceRadarWebNGWeb.Endpoint.url() do
      url when is_binary(url) ->
        trimmed = url |> String.trim() |> String.trim_trailing("/")
        if trimmed == "", do: nil, else: trimmed

      _other ->
        nil
    end
  rescue
    _ -> nil
  end

  defp request(provider, config, secrets, rendered) do
    %Request{
      delivery_id: nil,
      alert_id: nil,
      channel_id: nil,
      provider_key: Map.get(provider, :provider_key),
      provider_version: Map.get(provider, :definition_version),
      payload_format: rendered.payload_format,
      payload: rendered.payload,
      subject: rendered.subject,
      body: rendered.body,
      config: config,
      secrets: secrets,
      execution_route: :control_plane,
      attempt: 1,
      max_attempts: 1,
      is_test: true,
      metadata: %{"rendered_payload_digest" => rendered.digest}
    }
  end

  # --- result ----------------------------------------------------------------

  defp outcome(%Result{disposition: :delivered} = result, sensitive) do
    {:ok,
     %{
       status: :ok,
       headline: "The destination accepted the test notification",
       detail: nil,
       error_class: nil,
       summary: summary(result, sensitive)
     }}
  end

  defp outcome(%Result{} = result, sensitive) do
    {:error,
     %{
       status: :error,
       headline: headline(result.disposition),
       detail: redact_text(result.error_message, sensitive),
       error_class: result.error_class,
       summary: summary(result, sensitive)
     }}
  end

  defp outcome(other, _sensitive) do
    {:error, failure("The transport returned an unexpected result", inspect(other))}
  end

  defp headline(:retryable_failure), do: "The destination refused the test, and a retry could succeed"

  defp headline(_disposition), do: "The destination refused the test"

  defp summary(%Result{result_summary: summary}, sensitive) when is_map(summary) do
    summary
    |> ActionRedaction.redact()
    |> Enum.reject(fn {_key, value} -> is_map(value) or is_list(value) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(8)
    |> Enum.map(fn {key, value} ->
      {to_string(key), value |> to_string() |> scrub(sensitive) |> String.slice(0, 200)}
    end)
  end

  defp summary(_result, _sensitive), do: []

  defp redact_text(nil, _sensitive), do: nil

  defp redact_text(message, sensitive) when is_binary(message) do
    message
    |> scrub(sensitive)
    |> String.slice(0, 500)
  end

  defp redact_text(message, sensitive), do: message |> inspect() |> redact_text(sensitive)

  # ActionRedaction matches on key names; a credential echoed inside a message
  # VALUE has no key to match, so the operator's own typed secrets are scrubbed
  # by value as a second pass.
  defp scrub(text, sensitive) do
    sensitive
    |> Enum.filter(&(is_binary(&1) and String.length(&1) >= 4))
    |> Enum.reduce(text, &String.replace(&2, &1, "[redacted]"))
  end

  defp failure(headline, detail) do
    %{status: :error, headline: headline, detail: detail, error_class: nil, summary: []}
  end

  @doc "The redaction policy every displayed test result has passed."
  @spec redaction_policy() :: String.t()
  def redaction_policy, do: @redaction_policy
end
