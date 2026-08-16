defmodule ServiceRadar.Inventory.AdvisoryFeeds.Config do
  @moduledoc """
  Configuration + feature flags for core advisory feed ingestion (design D8).

  For operator-settable values (cadence, VulnCheck credential) the resolution
  order is: per-feed `VulnerabilityFeedDefinition` row column → application env
  override → environment variable → built-in default. The seeded feed-def row is
  therefore the primary source operators edit from the settings UI, with env as
  the fallback for un-seeded / pre-migration deployments. Feature flag
  `advisory_feeds_core_enabled` defaults **on** (demo); the nist-nvd2 sub-gate
  lets KEV enrichment run independently of the large NVD load.
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

  @refresh_seconds %{
    "cisa-kev" => 3_600,
    "vulncheck-kev" => 21_600,
    "nist-nvd2" => 86_400,
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

  @doc """
  VulnCheck API token.

  Primary source is a VulnCheck-backed feed-def row's `credential_ref` column,
  which stores a reusable `NetworkCredentialSecret` ID and resolves through the
  credential broker. Environment/application values remain plaintext fallback
  inputs for existing headless deployments.
  """
  @spec vulncheck_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def vulncheck_token(opts \\ []) do
    case definition_credential_ref() do
      ref when is_binary(ref) ->
        resolver = Keyword.get(opts, :credential_resolver, &CredentialResolver.resolve/2)
        resolver.(ref, opts)

      nil ->
        fallback_vulncheck_token()
    end
  end

  defp fallback_vulncheck_token do
    token =
      System.get_env("VULNCHECK_API_TOKEN") ||
        System.get_env("SERVICERADAR_VULNCHECK_TOKEN") ||
        config(:vulncheck_token, nil)

    case token do
      value when is_binary(value) -> present_token(value)
      _ -> {:error, :missing_vulncheck_token}
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
  # failure (repo down, no row, query error) so env/default fallback always wins.
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

  defp present_token(value) do
    case String.trim(value) do
      "" -> {:error, :missing_vulncheck_token}
      token -> {:ok, token}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
