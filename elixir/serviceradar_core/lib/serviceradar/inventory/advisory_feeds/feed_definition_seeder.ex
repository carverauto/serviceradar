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

  Existing rows are left unchanged except for the guarded enablement backfill;
  seeding does not refresh their definition metadata, cadence, or run status.
  The operator-facing defaults and upgrade policy are documented in
  `docs/docs/endpoint-software-security.md` under "Built-in feed enablement".
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
      {:ok, %VulnerabilityFeedDefinition{} = definition} ->
        maybe_enable_pristine(definition, entry, actor)

      {:ok, nil} ->
        create_definition(entry, actor)

      {:error, reason} ->
        Logger.warning(
          "advisory_feeds: feed-def seed check failed for #{entry.provider}/#{entry.feed_key}: #{inspect(reason)}"
        )
    end
  end

  defp default_enabled?(%{provider: "ubuntu", feed_key: "ubuntu-osv-vex"}), do: true
  defp default_enabled?(_), do: false

  # A row is seed-pristine when it never ran (no attempt of any outcome) and
  # no operator ever edited it (any settings-UI edit bumps `updated_at` past
  # `inserted_at`). Only pristine rows are backfilled, so an explicit operator
  # disable is never overwritten.
  defp seed_pristine?(%VulnerabilityFeedDefinition{
         enabled: false,
         last_attempt_at: nil,
         last_success_at: nil,
         last_failure_at: nil,
         inserted_at: %DateTime{} = inserted_at,
         updated_at: %DateTime{} = updated_at
       }) do
    DateTime.compare(inserted_at, updated_at) == :eq
  end

  defp seed_pristine?(_), do: false

  defp maybe_enable_pristine(definition, entry, actor) do
    if default_enabled?(entry) and seed_pristine?(definition) do
      definition
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update(actor: actor)
      |> case do
        {:ok, _definition} ->
          Logger.info(
            "advisory_feeds: enabled pristine feed definition #{entry.provider}/#{entry.feed_key}"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "advisory_feeds: failed to enable pristine feed definition #{entry.provider}/#{entry.feed_key}: #{inspect(reason)}"
          )
      end
    else
      :ok
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
      enabled: default_enabled?(entry),
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
