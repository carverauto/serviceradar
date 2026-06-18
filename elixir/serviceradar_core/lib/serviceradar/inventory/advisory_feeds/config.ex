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
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition

  require Ash.Query

  # Feed whose credential_ref carries the operator-supplied VulnCheck API token.
  @vulncheck_credential_feed "vulncheck-kev"

  @cisa_kev_url "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"

  @refresh_seconds %{
    "cisa-kev" => 3_600,
    "vulncheck-kev" => 21_600,
    "nist-nvd2" => 21_600,
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

  Primary source is the `vulncheck-kev` feed-def row's `credential_ref` column
  (operator-settable from the UI); falls back to env (`VULNCHECK_API_TOKEN`,
  `SERVICERADAR_VULNCHECK_TOKEN`) then app config. Returns
  `{:error, :missing_vulncheck_token}` when absent everywhere.
  """
  @spec vulncheck_token() :: {:ok, String.t()} | {:error, :missing_vulncheck_token}
  def vulncheck_token do
    token =
      definition_credential_ref() ||
        System.get_env("VULNCHECK_API_TOKEN") ||
        System.get_env("SERVICERADAR_VULNCHECK_TOKEN") ||
        config(:vulncheck_token, nil)

    case token do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_vulncheck_token}
    end
  end

  defp definition_credential_ref do
    with {:ok, entry} <- FeedRegistry.fetch(@vulncheck_credential_feed),
         %VulnerabilityFeedDefinition{credential_ref: ref} when is_binary(ref) and ref != "" <-
           read_definition(entry.provider, entry.feed_key) do
      ref
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
end
