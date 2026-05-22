defmodule ServiceRadar.OutboundMail do
  @moduledoc """
  Runtime outbound mail delivery backed by deployment-level mail settings.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.Mailer
  alias Swoosh.Adapters.Local

  @adapter_modules %{
    "local" => Local,
    "test" => Swoosh.Adapters.Test,
    "smtp" => Swoosh.Adapters.SMTP,
    "mailgun" => Swoosh.Adapters.Mailgun,
    "mandrill" => Swoosh.Adapters.Mandrill,
    "sendgrid" => Swoosh.Adapters.Sendgrid,
    "postmark" => Swoosh.Adapters.Postmark,
    "sparkpost" => Swoosh.Adapters.SparkPost,
    "amazon_ses" => Swoosh.Adapters.AmazonSES,
    "mailjet" => Swoosh.Adapters.Mailjet,
    "brevo" => Swoosh.Adapters.Brevo,
    "mailtrap" => Swoosh.Adapters.Mailtrap,
    "smtp2go" => Swoosh.Adapters.SMTP2GO
  }

  @provider_option_keys %{
    "api_key" => :api_key,
    "base_url" => :base_url,
    "domain" => :domain,
    "endpoint" => :endpoint,
    "region" => :region,
    "server" => :server,
    "tag" => :tag
  }

  @spec deliver(Swoosh.Email.t()) :: {:ok, term()} | {:error, term()}
  def deliver(email) do
    case active_config() do
      {:ok, config} -> Mailer.deliver(email, config)
      :disabled -> Mailer.deliver(email)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec from_tuple() :: {String.t(), String.t()}
  def from_tuple do
    case get_settings() do
      {:ok, %{from_name: name, from_email: email}} when is_binary(name) and is_binary(email) ->
        {name, email}

      _ ->
        mailer_config = Application.get_env(:serviceradar_core, Mailer, [])

        {Keyword.get(mailer_config, :from_name, "ServiceRadar"),
         Keyword.get(mailer_config, :from_email, "contact@example.com")}
    end
  end

  @spec active_config() :: {:ok, keyword()} | :disabled | {:error, term()}
  def active_config do
    case get_settings() do
      {:ok, %{enabled: true} = settings} -> config(settings)
      {:ok, _settings} -> :disabled
      {:error, reason} -> {:error, reason}
    end
  end

  @spec config(OutboundMailSettings.t()) :: {:ok, keyword()} | {:error, term()}
  def config(settings) do
    adapter = Map.get(@adapter_modules, settings.adapter, Local)

    with {:ok, password} <- resolved_secret(settings.password_secret_id, settings.password),
         {:ok, api_key} <- resolved_secret(settings.api_key_secret_id, settings.api_key) do
      config =
        [adapter: adapter]
        |> maybe_put(:relay, settings.relay)
        |> maybe_put(:port, settings.port)
        |> maybe_put(:hostname, settings.hostname)
        |> maybe_put(:username, settings.username)
        |> maybe_put(:password, password)
        |> maybe_put(:api_key, api_key)
        |> Keyword.put(:auth, mode_atom(settings.auth, :if_available))
        |> Keyword.put(:tls, mode_atom(settings.tls, :if_available))
        |> Keyword.put(:ssl, settings.ssl || false)
        |> Keyword.put(:retries, settings.retries || 1)
        |> Keyword.merge(provider_options(settings.provider_options || %{}))

      {:ok, config}
    end
  end

  defp get_settings do
    OutboundMailSettings.get_settings(actor: SystemActor.system(:outbound_mail))
  end

  defp resolved_secret(secret_id, _local_value) when is_binary(secret_id) and secret_id != "" do
    case SecretBroker.resolve_network_credential_secret(secret_id,
           actor: SystemActor.system(:outbound_mail_secret),
           resolution_location: :control_plane
         ) do
      {:ok, %{value: value}} -> {:ok, value}
      {:error, reason} -> {:error, {:mail_secret_resolution_failed, reason}}
    end
  end

  defp resolved_secret(_secret_id, local_value), do: {:ok, local_value}

  defp provider_options(options) when is_map(options) do
    Enum.reduce(options, [], fn {key, value}, acc ->
      case Map.get(@provider_option_keys, to_string(key)) do
        nil -> acc
        atom_key -> maybe_put(acc, atom_key, value)
      end
    end)
  end

  defp provider_options(_options), do: []

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, _key, ""), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)

  defp mode_atom("always", _default), do: :always
  defp mode_atom("never", _default), do: :never
  defp mode_atom("if_available", _default), do: :if_available
  defp mode_atom(_value, default), do: default
end
