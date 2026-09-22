defmodule ServiceRadar.Inventory.AdvisoryFeeds.Config do
  @moduledoc """
  Configuration + feature flags for core advisory feed ingestion (design D8).

  For the cadence the resolution order is: per-feed
  `VulnerabilityFeedDefinition` row column → application env override →
  environment variable → built-in default. The seeded feed-def row is therefore
  the primary source operators edit from the settings UI, with env as the
  fallback for un-seeded / pre-migration deployments.

  The VulnCheck credential does **not** follow that order. It comes from the
  feed row's `credential_ref` and nowhere else -- see `vulncheck_token/1`.

  Feature flag `advisory_feeds_core_enabled` defaults **on** (demo); the
  nist-nvd2 sub-gate lets KEV enrichment run independently of the large NVD
  load.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolver
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition

  require Ash.Query

  # Feeds whose credential_ref may carry the shared operator-supplied VulnCheck
  # credential-secret ID. The UI exposes the credential field on each VulnCheck-backed row,
  # so read both while preferring the KEV row for existing deployments.
  @vulncheck_credential_feeds ["vulncheck-kev", "nist-nvd2"]

  @cisa_kev_url "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
  @ubuntu_osv_url "https://security-metadata.canonical.com/osv/osv-all.tar.xz"
  @ubuntu_vex_url "https://security-metadata.canonical.com/vex/vex-all.tar.xz"

  # Recorded verbatim in the feed row's last_error, so it names both halves of
  # the operator's job: the credential does not exist until it is created, and
  # creating it does nothing until a feed row points at it.
  @missing_credential_message "no VulnCheck credential is attached to a VulnCheck-backed feed: " <>
                                "create a vulncheck API token credential at " <>
                                "/settings/networks/credentials, then select it on the " <>
                                "vulncheck-kev or nist-nvd2 row at " <>
                                "/settings/security/vulnerability-feeds"

  @refresh_seconds %{
    "cisa-kev" => 3_600,
    "vulncheck-kev" => 21_600,
    "nist-nvd2" => 21_600,
    "ubuntu-osv-vex" => 21_600,
    "nvd-api" => 21_600
  }

  @doc "Master feature flag for core advisory feeds (default: true)."
  @spec enabled?() :: boolean()
  def enabled? do
    config(:advisory_feeds_core_enabled, env_bool("SERVICERADAR_ADVISORY_FEEDS_ENABLED", true))
  end

  @doc "Sub-gate for the large nist-nvd2 load (default: true when enabled?)."
  @spec nist_nvd2_enabled?() :: boolean()
  def nist_nvd2_enabled? do
    config(
      :advisory_feeds_nist_nvd2_enabled,
      env_bool("SERVICERADAR_ADVISORY_NIST_NVD2_ENABLED", true)
    )
  end

  @doc "Per-feed operator gate from the feed-definition row."
  @spec feed_enabled?(String.t()) :: boolean()
  def feed_enabled?(feed) when is_binary(feed) do
    with {:ok, entry} <- FeedRegistry.fetch(feed),
         %VulnerabilityFeedDefinition{enabled: enabled} <-
           read_definition(entry.provider, entry.feed_key) do
      enabled == true
    else
      _ -> false
    end
  end

  def feed_enabled?(_feed), do: false

  @doc """
  Refresh cadence (seconds) for a feed.

  Primary source is the seeded feed-def row's `refresh_interval_seconds` column
  (operator-settable from the UI); falls back to the app-env override map, then
  the built-in per-feed default.
  """
  @spec refresh_seconds(String.t()) :: pos_integer()
  def refresh_seconds(feed) do
    case definition_refresh_seconds(feed) do
      seconds when is_integer(seconds) and seconds > 0 ->
        seconds

      _ ->
        overrides = config(:advisory_feed_refresh_seconds, %{})
        Map.get(overrides, feed) || Map.get(@refresh_seconds, feed, 21_600)
    end
  end

  defp definition_refresh_seconds(feed) do
    with {:ok, entry} <- FeedRegistry.fetch(feed),
         %VulnerabilityFeedDefinition{refresh_interval_seconds: seconds} <-
           read_definition(entry.provider, entry.feed_key) do
      seconds
    else
      _ -> nil
    end
  end

  @doc "CISA KEV feed URL."
  @spec cisa_kev_url() :: String.t()
  def cisa_kev_url do
    System.get_env("SERVICERADAR_CISA_KEV_URL") ||
      config(:cisa_kev_url, @cisa_kev_url)
  end

  @doc "Validated operator source for a registered feed."
  @spec source(String.t()) :: %{url: String.t(), options: map()} | {:error, term()}
  def source(feed) when is_binary(feed) do
    case FeedRegistry.fetch(feed) do
      {:ok, entry} ->
        default =
          if feed == "ubuntu-osv-vex",
            do: %{url: @ubuntu_osv_url, options: %{"vex_url" => @ubuntu_vex_url}}

        source =
          definition_source(entry.provider, entry.feed_key) ||
            application_source(feed) || default || {:error, :source_not_configured}

        validate_feed_source(feed, source)

      :error ->
        {:error, :unknown_feed}
    end
  end

  def source(_), do: {:error, :unknown_feed}

  defp validate_feed_source(
         "ubuntu-osv-vex",
         %{url: url, options: %{"vex_url" => vex_url}} = source
       )
       when is_binary(url) and is_binary(vex_url) do
    if present?(url) and present?(vex_url), do: source, else: {:error, :invalid_source_config}
  end

  defp validate_feed_source("ubuntu-osv-vex", _), do: {:error, :invalid_source_config}
  defp validate_feed_source(_feed, source), do: source

  defp definition_source(provider, feed_key) do
    case read_definition(provider, feed_key) do
      %VulnerabilityFeedDefinition{url: url, options: options} ->
        if present?(url), do: valid_source(url, options)

      _ ->
        nil
    end
  end

  defp application_source(feed) do
    :advisory_feed_sources
    |> config(%{})
    |> case do
      sources when is_map(sources) -> Map.get(sources, feed)
      _ -> nil
    end
    |> case do
      %{url: url} = source -> valid_source(url, Map.get(source, :options, %{}))
      %{"url" => url} = source -> valid_source(url, Map.get(source, "options", %{}))
      _ -> nil
    end
  end

  defp valid_source(url, options) when is_binary(url) and is_map(options) do
    allowed = ["vex_url"]

    if present?(url) and
         Enum.all?(options, fn {key, value} ->
           key in allowed and is_binary(value) and value != ""
         end) do
      %{url: url, options: options}
    else
      {:error, :invalid_source_config}
    end
  end

  defp valid_source(_url, _options), do: {:error, :invalid_source_config}

  @doc """
  VulnCheck API token.

  The only source is a VulnCheck-backed feed-def row's `credential_ref` column,
  which stores a reusable `NetworkCredentialSecret` ID and resolves through the
  credential broker. There is deliberately no environment or application-config
  fallback: an integration credential that arrives as plaintext in the process
  environment is never brokered, never audited, and never rotated, and a
  deployment that has both would silently run on whichever the code preferred.
  A missing credential is an error naming what to create.
  """
  @spec vulncheck_token(keyword()) ::
          {:ok, String.t()} | {:error, {:missing_vulncheck_credential, String.t()} | term()}
  def vulncheck_token(opts \\ []) do
    case definition_credential_ref() do
      ref when is_binary(ref) ->
        resolver = Keyword.get(opts, :credential_resolver, &CredentialResolver.resolve/2)
        resolver.(ref, opts)

      nil ->
        {:error, {:missing_vulncheck_credential, @missing_credential_message}}
    end
  end

  @doc """
  Whether a VulnCheck-backed feed row carries a `credential_ref`.

  This is the check a diagnostic wants: it reads the reference and stops there.
  `vulncheck_token/1` resolves through the credential broker, which mints a
  persisted grant and decrypts the secret, so calling it merely to decide
  whether to warn would materialize plaintext material nothing is about to use.
  """
  @spec vulncheck_credential_attached() ::
          :ok | {:error, {:missing_vulncheck_credential, String.t()}}
  def vulncheck_credential_attached do
    case definition_credential_ref() do
      ref when is_binary(ref) -> :ok
      nil -> {:error, {:missing_vulncheck_credential, @missing_credential_message}}
    end
  end

  defp definition_credential_ref do
    @vulncheck_credential_feeds
    |> Stream.map(&definition_credential_ref/1)
    |> Enum.find(&present?/1)
  end

  defp definition_credential_ref(feed) do
    with {:ok, entry} <- FeedRegistry.fetch(feed),
         %VulnerabilityFeedDefinition{credential_ref: ref} <-
           read_definition(entry.provider, entry.feed_key),
         true <- present?(ref) do
      String.trim(ref)
    else
      _ -> nil
    end
  end

  # Best-effort read of a feed-def row by provider/feed_key. Returns nil on any
  # failure (repo down, no row, query error) so the cadence default wins. For
  # the credential there is no default to fall back to: a repo failure reads as
  # "no credential", and the feed fails with the message rather than running on
  # something it found elsewhere.
  defp read_definition(provider, feed_key) do
    if repo_ready?() do
      actor = SystemActor.system(:advisory_feeds_config)

      VulnerabilityFeedDefinition
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %VulnerabilityFeedDefinition{} = definition} -> definition
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp repo_ready? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end

  defp config(key, default) do
    :serviceradar_core
    |> Application.get_env(:advisory_feeds, [])
    |> Keyword.get(key, default)
  end

  defp env_bool(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
