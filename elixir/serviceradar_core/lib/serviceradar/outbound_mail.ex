defmodule ServiceRadar.OutboundMail do
  @moduledoc """
  The single outbound mail path for ServiceRadar.

  Everything that sends mail - the identity senders (confirmation, password
  reset) and the `:native` notification email transport
  (`ServiceRadar.Notifications.Transports.Email`) - builds a `Swoosh.Email` and
  hands it to `deliver/1`. There is deliberately no second mailer: a second path
  is a second place for the adapter, the credential, and the `from` address to be
  resolved differently, and mail that silently goes nowhere is the hardest
  failure in this system to notice.

  ## Where the configuration comes from

  In precedence order:

    1. `ServiceRadar.Integrations.OutboundMailSettings` when a settings row
       exists and is `enabled` - the operator-managed configuration, with its
       password and API key resolved through
       `ServiceRadar.Credentials.SecretBroker`.
    2. Otherwise the deployment configuration,
       `config :serviceradar_core, ServiceRadar.Mailer, ...`, which
       `config/runtime.exs` builds from `SERVICERADAR_MAILER_ADAPTER` and the
       `SMTP_RELAY_*` environment (see
       `ServiceRadar.OutboundMail.RuntimeConfig`).

  A missing settings row is **not** an error: it means "no operator override",
  and the deployment configuration applies. That is what lets an operator
  configure SMTP entirely through Helm and never open the settings page.

  ## Diagnosing a mailer that will not deliver

  `diagnose/0` exists because the default Swoosh adapters *succeed*.
  `Swoosh.Adapters.Test` returns `{:ok, email}` and sends the message to the
  current test process; `Swoosh.Adapters.Local` returns `{:ok, email}` and files
  it in an in-memory mailbox nobody reads in production. A notification channel
  pointed at either one reports every delivery as `:sent` and pages nobody -
  which looks exactly like a working channel until an incident proves otherwise.

  So `diagnose/0` names the specific reason mail will not leave the deployment,
  and callers surface it at configuration time rather than discovering it during
  an outage. `Swoosh.Adapters.SMTP` additionally requires the `gen_smtp`
  dependency: swoosh declares it *optional*, so without it an SMTP configuration
  compiles and deploys and then fails at the first send.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.Mailer
  alias Swoosh.Adapters.Brevo
  alias Swoosh.Adapters.Local
  alias Swoosh.Adapters.Mailgun
  alias Swoosh.Adapters.Mailjet
  alias Swoosh.Adapters.Mailtrap
  alias Swoosh.Adapters.Mandrill
  alias Swoosh.Adapters.Postmark
  alias Swoosh.Adapters.Sendgrid
  alias Swoosh.Adapters.SMTP
  alias Swoosh.Adapters.SMTP2GO
  alias Swoosh.Adapters.SparkPost
  alias Swoosh.Adapters.Test

  @adapter_modules %{
    "local" => Local,
    "test" => Test,
    "smtp" => SMTP,
    "mailgun" => Mailgun,
    "mandrill" => Mandrill,
    "sendgrid" => Sendgrid,
    "postmark" => Postmark,
    "sparkpost" => SparkPost,
    "amazon_ses" => Swoosh.Adapters.AmazonSES,
    "mailjet" => Mailjet,
    "brevo" => Brevo,
    "mailtrap" => Mailtrap,
    "smtp2go" => SMTP2GO
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

  # Adapters that accept a message and deliver it nowhere. Both answer `{:ok,
  # _}`, which is why they have to be named rather than detected.
  @non_delivering_adapters [Test, Local]

  # Adapters whose only credential is `:api_key`. AmazonSES is excluded on
  # purpose: it authenticates with an access key and secret, so an `:api_key`
  # check would report a problem that is not one.
  @api_key_adapters [
    Mailgun,
    Mandrill,
    Sendgrid,
    Postmark,
    SparkPost,
    Mailjet,
    Brevo,
    Mailtrap,
    SMTP2GO
  ]

  @smtp_adapter SMTP

  @typedoc """
  A reason mail will not leave this deployment: a stable class plus an
  operator-readable sentence that names the setting or environment variable to
  change.
  """
  @type diagnostic :: {atom(), String.t()}

  @doc """
  Sends one message.

  `config` is an already-resolved mailer configuration - what `effective_config/0`
  returned. Passing it matters for a caller that diagnosed the mailer first: it
  makes the message go out through exactly the configuration that was judged,
  and it resolves the settings row and its credentials once instead of twice
  per send. `nil` (the default) resolves them here.
  """
  @spec deliver(Swoosh.Email.t(), keyword() | nil) :: {:ok, term()} | {:error, term()}
  def deliver(email, config \\ nil)

  def deliver(email, config) when is_list(config), do: Mailer.deliver(email, config)

  def deliver(email, nil) do
    case active_config() do
      {:ok, config} -> Mailer.deliver(email, config)
      :disabled -> Mailer.deliver(email)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a transactional identity email (confirmation, password reset).

  Absorbed from the former `ServiceRadar.Identity.Senders.EmailDelivery`, which
  called `ServiceRadar.Mailer.deliver/1` directly and therefore ignored the
  operator's outbound mail settings entirely - including the `from` address they
  had configured. Routing it through `deliver/1` puts every message this
  deployment sends on one path.
  """
  @spec deliver_transactional(map(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def deliver_transactional(user, subject, url, opts) do
    email_address = to_string(user.email)
    display_name = user.display_name || email_address

    [
      to: {display_name, email_address},
      from: from_tuple(),
      subject: subject,
      html_body: transactional_html_body(url, opts),
      text_body: transactional_text_body(url, opts)
    ]
    |> Swoosh.Email.new()
    |> deliver()
  end

  @doc """
  The base URL used to build links in transactional email.
  """
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
  end

  @spec from_tuple() :: {String.t(), String.t()}
  def from_tuple do
    case get_settings() do
      {:ok, %{from_name: name, from_email: email}} when is_binary(name) and is_binary(email) ->
        {name, email}

      _ ->
        default_from_tuple()
    end
  rescue
    # A settings store that cannot be read must not stop a message from being
    # addressed: the deployment `From:` is the whole point of the fallback, and
    # raising here would turn an unreadable settings row into an unclassifiable
    # transport exception.
    _exception -> default_from_tuple()
  catch
    _kind, _reason -> default_from_tuple()
  end

  defp default_from_tuple do
    mailer_config = application_config()

    {Keyword.get(mailer_config, :from_name, "ServiceRadar"),
     Keyword.get(mailer_config, :from_email, "contact@example.com")}
  end

  @spec active_config() :: {:ok, keyword()} | :disabled | {:error, term()}
  def active_config do
    case get_settings() do
      {:ok, %{enabled: true} = settings} -> config(settings)
      {:ok, _settings} -> :disabled
      # No settings row is "no operator override", not a failure: the deployment
      # configuration applies. Treating it as an error is what made a
      # Helm-configured relay unusable until somebody opened the settings page.
      {:error, reason} -> if settings_absent?(reason), do: :disabled, else: {:error, reason}
    end
  end

  @doc """
  The mailer configuration `deliver/1` would actually use for the next message.

  This is the input `diagnose/1` classifies, and it is deliberately the same
  resolution `deliver/1` performs, so a diagnostic cannot describe a
  configuration different from the one that sends.
  """
  @spec effective_config() :: {:ok, keyword()} | {:error, term()}
  def effective_config do
    case active_config() do
      {:ok, config} -> {:ok, config}
      :disabled -> {:ok, application_config()}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A settings store that raises is reported, never papered over with the
    # deployment configuration: `deliver/1` reads the same row and would fail
    # too, and a diagnostic that describes a configuration the sender will not
    # use is worse than no diagnostic.
    exception -> {:error, exception}
  catch
    _kind, reason -> {:error, reason}
  end

  @doc """
  The deployment-level mailer configuration, before any operator override.
  """
  @spec application_config() :: keyword()
  def application_config do
    case Application.get_env(:serviceradar_core, Mailer, []) do
      config when is_list(config) -> config
      _other -> []
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

  @doc """
  Reports why the resolved mailer will not deliver mail, or `:ok`.

  See `diagnose/1` for the classes. This arity resolves the configuration first
  and reports `:mail_settings_unavailable` when that resolution itself fails -
  a credential store that is briefly unreachable, for example, which is worth
  retrying rather than treating as a broken channel.
  """
  @spec diagnose() :: :ok | {:error, diagnostic()}
  def diagnose, do: diagnose(effective_config())

  @doc """
  Classifies a mailer configuration, or the result of resolving one.

  Accepts a keyword list, or `effective_config/0`'s `{:ok, config}` /
  `{:error, reason}` - so a caller that already resolved the configuration
  classifies that exact value rather than resolving it a second time, which
  costs a settings read and a credential-broker call each time.

  Returns `:ok`, or `{:error, {class, message}}` where `class` is one of:

    * `:mail_settings_unavailable` - the configuration could not be resolved at
      all. Transient; worth retrying rather than treating as a broken channel.
    * `:mailer_not_configured` - no adapter at all
    * `:non_delivering_adapter` - `Swoosh.Adapters.Test` or
      `Swoosh.Adapters.Local`; both report success and deliver nothing
    * `:smtp_dependency_missing` - `Swoosh.Adapters.SMTP` without `gen_smtp`
    * `:smtp_relay_missing` - `Swoosh.Adapters.SMTP` with no relay host
    * `:api_key_missing` - an API adapter with no API key
    * `:api_client_disabled` - an API adapter while `config :swoosh, :api_client`
      is `false`, which makes every send raise
    * `:unknown_adapter` - the configured adapter module is not in this release

  The message names the setting or environment variable to change, because a
  diagnostic an operator cannot act on is only a slightly better silence.
  """
  @spec diagnose(keyword() | {:ok, keyword()} | {:error, term()}) :: :ok | {:error, diagnostic()}
  def diagnose(config) when is_list(config) do
    adapter = Keyword.get(config, :adapter)

    cond do
      is_nil(adapter) ->
        {:error,
         {:mailer_not_configured,
          "no outbound mail adapter is configured; set SERVICERADAR_MAILER_ADAPTER=smtp with " <>
            "SMTP_RELAY_HOST, or enable outbound mail in Settings > Mail"}}

      adapter in @non_delivering_adapters ->
        {:error, {:non_delivering_adapter, non_delivering_message(adapter)}}

      adapter == @smtp_adapter ->
        smtp_diagnostic(config)

      not adapter_available?(adapter) ->
        {:error,
         {:unknown_adapter,
          "the configured mail adapter #{inspect(adapter)} is not part of this release; " <>
            "check SERVICERADAR_MAILER_ADAPTER"}}

      true ->
        api_diagnostic(adapter, config)
    end
  end

  def diagnose({:ok, config}), do: diagnose(config)

  def diagnose({:error, reason}) do
    {:error,
     {:mail_settings_unavailable,
      "the outbound mail settings could not be read (#{describe_reason(reason)}); " <>
        "check the settings store and the credential broker"}}
  end

  def diagnose(_config) do
    {:error,
     {:mailer_not_configured,
      "the outbound mail configuration is not a keyword list; set " <>
        "SERVICERADAR_MAILER_ADAPTER and the matching SMTP_RELAY_* environment"}}
  end

  @doc "The adapter module for a stored adapter name, or nil."
  @spec adapter_module(String.t()) :: module() | nil
  def adapter_module(name) when is_binary(name), do: Map.get(@adapter_modules, name)
  def adapter_module(_name), do: nil

  @doc "The adapters that accept a message and deliver it nowhere."
  @spec non_delivering_adapters() :: [module()]
  def non_delivering_adapters, do: @non_delivering_adapters

  # --- diagnostics ----------------------------------------------------------

  defp non_delivering_message(Test) do
    "the mailer resolves to Swoosh.Adapters.Test, which reports every send as " <>
      "successful and delivers nothing; set SERVICERADAR_MAILER_ADAPTER=smtp with " <>
      "SMTP_RELAY_HOST (and SMTP_RELAY_PORT / SMTP_RELAY_USERNAME / SMTP_RELAY_PASSWORD " <>
      "as the relay requires), or enable outbound mail in Settings > Mail"
  end

  defp non_delivering_message(_local) do
    "the mailer resolves to Swoosh.Adapters.Local, the in-memory development " <>
      "mailbox: it reports every send as successful and no mail leaves this deployment; " <>
      "unset SERVICERADAR_LOCAL_MAILER and set SERVICERADAR_MAILER_ADAPTER=smtp with " <>
      "SMTP_RELAY_HOST, or enable outbound mail in Settings > Mail"
  end

  # `gen_smtp` is swoosh's *optional* dependency, so `Swoosh.Adapters.SMTP`
  # exists whether or not it can work. The honest check is whether the gen_smtp
  # client module is in this release.
  defp smtp_diagnostic(config) do
    cond do
      not Code.ensure_loaded?(:gen_smtp_client) ->
        {:error,
         {:smtp_dependency_missing,
          "Swoosh.Adapters.SMTP needs the gen_smtp dependency, which is not in this " <>
            "release; add {:gen_smtp, \"~> 1.2\"} to elixir/serviceradar_core/mix.exs"}}

      blank?(Keyword.get(config, :relay)) ->
        {:error,
         {:smtp_relay_missing,
          "Swoosh.Adapters.SMTP is configured with no relay host; set SMTP_RELAY_HOST, " <>
            "or set the relay in Settings > Mail"}}

      true ->
        :ok
    end
  end

  defp api_diagnostic(adapter, config) do
    cond do
      adapter in @api_key_adapters and blank?(Keyword.get(config, :api_key)) ->
        {:error,
         {:api_key_missing,
          "#{inspect(adapter)} is configured with no API key; set the API key in " <>
            "Settings > Mail"}}

      Application.get_env(:swoosh, :api_client) == false ->
        {:error,
         {:api_client_disabled,
          "#{inspect(adapter)} needs an HTTP client but config :swoosh, :api_client is " <>
            "false; set it to Swoosh.ApiClient.Req"}}

      true ->
        :ok
    end
  end

  defp adapter_available?(adapter) when is_atom(adapter), do: Code.ensure_loaded?(adapter)
  defp adapter_available?(_adapter), do: false

  # Only the error's shape reaches an operator-visible sentence. An Ash error
  # struct inspected in full is both unreadable and a place a resolved secret
  # could ride along.
  defp describe_reason(%module{}), do: inspect(module)
  defp describe_reason(reason) when is_atom(reason), do: inspect(reason)
  defp describe_reason({reason, _detail}) when is_atom(reason), do: inspect(reason)
  defp describe_reason(_reason), do: "unknown error"

  # --- settings -------------------------------------------------------------

  defp get_settings do
    OutboundMailSettings.get_settings(actor: SystemActor.system(:outbound_mail))
  end

  defp settings_absent?(%Ash.Error.Query.NotFound{}), do: true

  defp settings_absent?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &settings_absent?/1)

  defp settings_absent?(:not_found), do: true
  defp settings_absent?(_reason), do: false

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

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # --- transactional bodies -------------------------------------------------

  defp transactional_html_body(url, opts) do
    """
    <h2>#{Keyword.fetch!(opts, :heading)}</h2>
    <p>#{Keyword.fetch!(opts, :intro)}</p>
    <p><a href="#{url}" target="_blank">#{Keyword.fetch!(opts, :link_label)}</a></p>
    <p>#{Keyword.fetch!(opts, :expiry)}</p>
    <p>#{Keyword.fetch!(opts, :ignore)}</p>
    """
  end

  defp transactional_text_body(url, opts) do
    """
    #{Keyword.fetch!(opts, :heading)}

    #{Keyword.fetch!(opts, :intro)}

    #{url}

    #{Keyword.fetch!(opts, :expiry)}

    #{Keyword.fetch!(opts, :ignore)}
    """
  end
end
