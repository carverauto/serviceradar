defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedDefinitionSeeder do
  @moduledoc """
  Seeds one `VulnerabilityFeedDefinition` row per core advisory feed at boot.

  Advisory feeds run in core on an AshOban schedule, but nothing previously
  created the `platform.vulnerability_feed_definitions` rows the worker writes
  status into — `FeedWorker.mark_status/3` only *updates* an existing row and
  silently drops the write otherwise. This seeder materializes the rows from the
  canonical `FeedRegistry`, keyed on the `:unique_provider_feed` identity, so:

    * the Vulnerability Intelligence settings page lists every feed (showing
      "never") before the first run; and
    * the worker's status writes always land.

  The upsert is idempotent and only touches definition metadata
  (`display_name`/`feed_type`/`refresh_interval_seconds`); it never overwrites
  operator-set `enabled`, cadence-changes the operator may make, or run status.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AdvisoryFeeds.Config
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition

  require Ash.Query
  require Logger

  @spec seed_defaults() :: :ok
  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:advisory_feed_definition_seeder)
      Enum.each(FeedRegistry.all(), &ensure_definition(&1, actor))
      warn_missing_vulncheck_credential()
    end

    :ok
  end

  defp warn_missing_vulncheck_credential do
    case Config.vulncheck_credential_attached() do
      {:error, {:missing_vulncheck_credential, message}} ->
        Logger.warning("advisory_feeds: #{message}")

      :ok ->
        :ok
    end
  end

  defp ensure_definition(entry, actor) do
    case existing(entry, actor) do
      {:ok, %VulnerabilityFeedDefinition{}} ->
        :ok

      {:ok, nil} ->
        create_definition(entry, actor)

      {:error, reason} ->
        Logger.warning(
          "advisory_feeds: feed-def seed check failed for #{entry.provider}/#{entry.feed_key}: #{inspect(reason)}"
        )
    end
  end

  defp existing(entry, actor) do
    VulnerabilityFeedDefinition
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(provider == ^entry.provider and feed_key == ^entry.feed_key)
    |> Ash.read_one(actor: actor)
  end

  defp create_definition(entry, actor) do
    attrs = %{
      provider: entry.provider,
      feed_key: entry.feed_key,
      display_name: entry.display_name,
      feed_type: entry.feed_type,
      refresh_interval_seconds: entry.refresh_interval_seconds,
      metadata: %{"source" => "core-scheduled"}
    }

    VulnerabilityFeedDefinition
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _definition} ->
        Logger.info("advisory_feeds: seeded feed definition #{entry.provider}/#{entry.feed_key}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "advisory_feeds: failed to seed feed definition #{entry.provider}/#{entry.feed_key}: #{inspect(reason)}"
        )
    end
  end
end
