defmodule ServiceRadar.Inventory.AdvisoryFeeds.Config do
  @moduledoc """
  Configuration + feature flags for core advisory feed ingestion (design D8).

  Resolution order for each value: application env override → environment
  variable → built-in default. Feature flag `advisory_feeds_core_enabled`
  defaults **on** (demo); the nist-nvd2 sub-gate lets KEV enrichment run
  independently of the large NVD load.
  """

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

  @doc "Refresh cadence (seconds) for a feed."
  @spec refresh_seconds(String.t()) :: pos_integer()
  def refresh_seconds(feed) do
    overrides = config(:advisory_feed_refresh_seconds, %{})
    Map.get(overrides, feed) || Map.get(@refresh_seconds, feed, 21_600)
  end

  @doc "CISA KEV feed URL."
  @spec cisa_kev_url() :: String.t()
  def cisa_kev_url do
    System.get_env("SERVICERADAR_CISA_KEV_URL") ||
      config(:cisa_kev_url, @cisa_kev_url)
  end

  @doc """
  VulnCheck API token. Read from env (`VULNCHECK_API_TOKEN`) or app config.
  Returns `{:error, :missing_vulncheck_token}` when absent.
  """
  @spec vulncheck_token() :: {:ok, String.t()} | {:error, :missing_vulncheck_token}
  def vulncheck_token do
    token =
      System.get_env("VULNCHECK_API_TOKEN") ||
        System.get_env("SERVICERADAR_VULNCHECK_TOKEN") ||
        config(:vulncheck_token, nil)

    case token do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_vulncheck_token}
    end
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
