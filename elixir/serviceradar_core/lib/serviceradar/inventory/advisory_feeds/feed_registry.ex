defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry do
  @moduledoc """
  Canonical metadata for the core advisory feeds (design D1).

  One entry per `FeedWorker` feed key. This is the single source of truth shared
  by:

    * the boot-time `FeedDefinitionSeeder`, which materializes one
      `VulnerabilityFeedDefinition` row per feed so the UI shows "never" before
      the first run and so `FeedWorker.mark_status/3` always finds a row to
      update;
    * the on-demand `:run_now` action, which maps a feed-definition row
      (`provider` + `feed_key`) back to the `FeedWorker` feed key; and
    * `Config`, which reads operator-settable cadence and credential refs off the
      seeded row.

  Keeping the `provider`/`feed_key` identity here in lock-step with
  `FeedWorker.provider_feed/1` guarantees the seeded rows line up with the status
  writes the worker performs.
  """

  @default_feed_type "addon_normalized_advisory_feed"

  @feeds [
    %{
      feed: "cisa-kev",
      provider: "cisa",
      feed_key: "cisa-kev",
      display_name: "CISA Known Exploited Vulnerabilities",
      feed_type: @default_feed_type,
      requires_credential: false,
      refresh_interval_seconds: 3_600
    },
    %{
      feed: "vulncheck-kev",
      provider: "vulncheck",
      feed_key: "vulncheck-kev",
      display_name: "VulnCheck KEV",
      feed_type: @default_feed_type,
      requires_credential: true,
      refresh_interval_seconds: 21_600
    },
    %{
      feed: "nist-nvd2",
      provider: "nvd",
      feed_key: "nist-nvd2",
      display_name: "VulnCheck nist-nvd2 (NVD CPE)",
      feed_type: @default_feed_type,
      requires_credential: true,
      refresh_interval_seconds: 21_600
    },
    %{
      feed: "ubuntu-osv-vex",
      provider: "ubuntu",
      feed_key: "ubuntu-osv-vex",
      display_name: "Ubuntu OSV + OpenVEX",
      feed_type: @default_feed_type,
      requires_credential: false,
      refresh_interval_seconds: 21_600
    }
  ]

  @type entry :: %{
          feed: String.t(),
          provider: String.t(),
          feed_key: String.t(),
          display_name: String.t(),
          feed_type: String.t(),
          requires_credential: boolean(),
          refresh_interval_seconds: pos_integer()
        }

  @doc "All registry entries."
  @spec all() :: [entry()]
  def all, do: @feeds

  @doc "Lookup a registry entry by `FeedWorker` feed key."
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(feed) when is_binary(feed) do
    case Enum.find(@feeds, &(&1.feed == feed)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  def fetch(_feed), do: :error

  @doc """
  Map a feed-definition `provider`/`feed_key` pair back to the `FeedWorker` feed
  key. Returns `:error` when the pair is not a known core advisory feed.
  """
  @spec feed_for(String.t(), String.t()) :: {:ok, String.t()} | :error
  def feed_for(provider, feed_key) when is_binary(provider) and is_binary(feed_key) do
    case Enum.find(@feeds, &(&1.provider == provider and &1.feed_key == feed_key)) do
      nil -> :error
      entry -> {:ok, entry.feed}
    end
  end

  def feed_for(_provider, _feed_key), do: :error
end
