defmodule ServiceRadar.OutboundMail.RuntimeConfig do
  @moduledoc """
  Builds `config :serviceradar_core, ServiceRadar.Mailer, ...` from the
  deployment environment.

  This is a pure function of an environment map so both releases that carry
  `serviceradar_core` - `serviceradar_core_elx` and `web-ng` - can derive the
  same mailer from the same variables without a second copy of the rules, and so
  the rules can be tested without a release.

  ## Variables

  | Variable | Meaning |
  | --- | --- |
  | `SERVICERADAR_MAILER_ADAPTER` | `smtp`, `local`, `test`, or any name in `ServiceRadar.OutboundMail.adapter_module/1` |
  | `SERVICERADAR_CORE_MAILER_ADAPTER` | Same, and takes precedence; lets one deployment differ from web-ng |
  | `SMTP_RELAY_HOST` | Relay hostname. Setting it selects the SMTP adapter when no adapter is named |
  | `SMTP_RELAY_PORT` | Relay port, default 587 |
  | `SMTP_RELAY_HOSTNAME` | HELO/EHLO name this deployment announces |
  | `SMTP_RELAY_USERNAME` / `SMTP_RELAY_PASSWORD` | Relay credentials |
  | `SMTP_RELAY_AUTH` | `always`, `never`, `if_available` (default) |
  | `SMTP_RELAY_TLS` | `always`, `never`, `if_available` (default) |
  | `SMTP_RELAY_SSL` | `true` for implicit TLS (port 465) |
  | `SERVICERADAR_MAIL_FROM_NAME` / `SERVICERADAR_MAIL_FROM_EMAIL` | Default `From:` |
  | `SERVICERADAR_LOCAL_MAILER` | Legacy switch for the in-memory development mailbox |

  ## Two decisions worth stating

  **The adapter name is resolved through an allowlist, never `String.to_atom/1`.**
  `Module.concat/1` on a deployment-supplied string turns an environment
  variable into "load any module in the release", which is the same class of
  mistake the notification transport registry exists to prevent. An unknown name
  raises at boot with the accepted list, which is a deployment that fails to
  start rather than one that starts and mails nowhere.

  **A bare `SMTP_RELAY_HOST` selects SMTP.** An operator who supplied a relay
  meant to send mail through it, and requiring a second variable to say so is a
  step whose only possible outcome is being forgotten.

  What this module deliberately does NOT do is invent a working default. With no
  adapter and no relay it resolves to `Swoosh.Adapters.Test`, exactly as before -
  and `ServiceRadar.OutboundMail.diagnose/0` is what makes that state visible
  instead of silent.
  """

  alias ServiceRadar.OutboundMail
  alias ServiceRadar.OutboundMail.SmtpTls
  alias Swoosh.Adapters.Local

  @default_port 587
  @default_from_name "ServiceRadar"
  @default_from_email "noreply@serviceradar.cloud"

  @truthy ~w(true 1 yes on)

  @smtp_adapter Swoosh.Adapters.SMTP
  @test_adapter Swoosh.Adapters.Test

  @doc """
  The mailer keyword list for this environment.

  Raises when `SERVICERADAR_MAILER_ADAPTER` names an adapter that is not
  allowlisted: a typo there is a deployment that silently stops sending mail,
  and failing to boot is the cheaper outcome.
  """
  @spec mailer_config(map()) :: keyword()
  def mailer_config(env \\ System.get_env()) when is_map(env) do
    adapter = adapter(env)

    Keyword.merge(
      [
        adapter: adapter,
        from_name: get(env, "SERVICERADAR_MAIL_FROM_NAME") || @default_from_name,
        from_email: get(env, "SERVICERADAR_MAIL_FROM_EMAIL") || @default_from_email
      ],
      smtp_options(adapter, env)
    )
  end

  @doc """
  Whether `config :swoosh, local: ...` should be true - that is, whether the
  resolved adapter is the in-memory development mailbox.
  """
  @spec local?(map()) :: boolean()
  def local?(env \\ System.get_env()) when is_map(env), do: adapter(env) == Local

  @doc "The adapter this environment resolves to."
  @spec adapter(map()) :: module()
  def adapter(env) when is_map(env) do
    case get(env, "SERVICERADAR_CORE_MAILER_ADAPTER") || get(env, "SERVICERADAR_MAILER_ADAPTER") do
      nil -> inferred_adapter(env)
      name -> named_adapter(name)
    end
  end

  defp inferred_adapter(env) do
    cond do
      truthy?(get(env, "SERVICERADAR_LOCAL_MAILER")) -> Local
      get(env, "SMTP_RELAY_HOST") -> @smtp_adapter
      true -> @test_adapter
    end
  end

  defp named_adapter(name) do
    case OutboundMail.adapter_module(String.downcase(name)) do
      nil ->
        raise ArgumentError,
              "SERVICERADAR_MAILER_ADAPTER=#{name} is not a supported outbound mail adapter; " <>
                "supported adapters are " <> Enum.join(supported_adapter_names(), ", ")

      adapter ->
        adapter
    end
  end

  defp supported_adapter_names do
    ~w(local test smtp mailgun mandrill sendgrid postmark sparkpost amazon_ses mailjet brevo mailtrap smtp2go)
  end

  defp smtp_options(@smtp_adapter, env) do
    [
      relay: get(env, "SMTP_RELAY_HOST"),
      port: port(env),
      hostname: get(env, "SMTP_RELAY_HOSTNAME"),
      auth: mode(get(env, "SMTP_RELAY_AUTH")),
      tls: mode(get(env, "SMTP_RELAY_TLS")),
      ssl: truthy?(get(env, "SMTP_RELAY_SSL")),
      retries: 1
    ]
    |> put_present(:username, get(env, "SMTP_RELAY_USERNAME"))
    |> put_present(:password, get(env, "SMTP_RELAY_PASSWORD"))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> SmtpTls.attach()
  end

  defp smtp_options(_adapter, _env), do: []

  defp port(env) do
    case get(env, "SMTP_RELAY_PORT") do
      nil ->
        @default_port

      value ->
        case Integer.parse(value) do
          {port, _rest} when port > 0 and port <= 65_535 -> port
          _other -> @default_port
        end
    end
  end

  defp mode("always"), do: :always
  defp mode("never"), do: :never
  defp mode(_value), do: :if_available

  defp put_present(config, _key, nil), do: config
  defp put_present(config, key, value), do: Keyword.put(config, key, value)

  defp get(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp truthy?(value) when is_binary(value), do: String.downcase(value) in @truthy
  defp truthy?(_value), do: false
end
