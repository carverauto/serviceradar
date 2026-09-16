defmodule ServiceRadar.AnalyticsStore.FileManifest do
  @moduledoc """
  Verified Parquet object on the analytics store.

  Lives on the primary CNPG (the analytics head is disposable). Readers and
  head-view rebuilds use published keys; staging keys never appear under
  `date=*`.
  """

  use Ash.Resource,
    domain: ServiceRadar.AnalyticsStore.Catalog,
    data_layer: AshPostgres.DataLayer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.AnalyticsStore.ManifestCompaction

  postgres do
    table "analytics_file_manifest"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [
        :table_name,
        :object_key,
        :staging_key,
        :partition_date,
        :row_count,
        :min_timestamp,
        :max_timestamp,
        :content_checksum,
        :batch_id,
        :archive_batch_id,
        :status
      ]

      upsert? true
      upsert_identity :object_key
    end

    create :compact do
      accept [
        :table_name,
        :object_key,
        :staging_key,
        :partition_date,
        :row_count,
        :min_timestamp,
        :max_timestamp,
        :content_checksum,
        :batch_id
      ]
    end

    update :supersede do
      accept [:retired_at, :replacement_key]
      change set_attribute(:status, :superseded)
    end

    update :expire do
      accept [:retired_at]
      change set_attribute(:status, :expired)
    end

    update :mark_objects_deleted do
      accept [:objects_deleted_at]
    end
  end

  attributes do
    integer_primary_key :id, writable?: false, generated?: true

    attribute :table_name, :string, allow_nil?: false
    attribute :object_key, :string, allow_nil?: false
    attribute :staging_key, :string, allow_nil?: false
    attribute :partition_date, :date, allow_nil?: false
    attribute :row_count, :integer
    attribute :min_timestamp, :utc_datetime_usec
    attribute :max_timestamp, :utc_datetime_usec
    attribute :content_checksum, :string
    attribute :batch_id, :string, allow_nil?: false
    attribute :archive_batch_id, :uuid

    attribute :status, :atom,
      allow_nil?: false,
      default: :published,
      constraints: [one_of: [:pending, :verified, :published, :superseded, :expired]]

    attribute :retired_at, :utc_datetime_usec
    attribute :replacement_key, :string
    attribute :objects_deleted_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :partition_files, __MODULE__ do
      source_attribute :partition_date
      destination_attribute :partition_date
      filter expr(table_name == parent(table_name))
    end
  end

  identities do
    identity :object_key, [:object_key]
    identity :archive_batch_id, [:archive_batch_id]
  end

  @doc "Record a published object. Used by the pg_duckdb writer."
  @spec record(map()) :: :ok | {:error, term()}
  def record(attrs) when is_map(attrs) do
    case __MODULE__
         |> Ash.Changeset.for_create(:record, attrs)
         |> Ash.create(actor: SystemActor.system(:analytics_store)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Publish a verified compacted object and retire its unchanged source snapshot atomically."
  defdelegate replace_sources(sources, attrs, opts \\ []), to: ManifestCompaction

  @doc "Read one eligible legacy metric file for an explicit sorted rewrite."
  defdelegate rewrite_source(table, manifest_id, opts \\ []), to: ManifestCompaction

  @doc "Publish a verified single-file rewrite and retain its original manifest lineage."
  defdelegate replace_rewrite(source, attrs, opts \\ []), to: ManifestCompaction

  @doc "Bounded, same-day files eligible for compaction; excludes recently published objects."
  defdelegate compaction_candidates(table, opts \\ []), to: ManifestCompaction

  @doc "Retire a bounded expired partition snapshot while preserving archive provenance."
  defdelegate retire_expired(table, cutoff, opts \\ []), to: ManifestCompaction

  @doc "Superseded or expired objects whose reader grace period has elapsed."
  defdelegate retired_files(table, before, limit \\ 256), to: ManifestCompaction

  @doc "Retain source membership after the retired objects have been deleted and verified absent."
  defdelegate mark_objects_deleted(id, opts \\ []), to: ManifestCompaction

  @doc "Prevent legacy delete-first pruning after a table has used durable hybrid publication."
  def ensure_legacy_prune_allowed(table) do
    require Ash.Query

    ArchiveBatch
    |> Ash.Query.filter(table_name == ^table)
    |> Ash.exists(actor: SystemActor.system(:analytics_store))
    |> case do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :hybrid_archive_retention_required}
      {:error, _} = error -> error
    end
  end

  @doc "Published object keys whose partition_date is strictly before `cutoff`."
  @spec expired_keys(String.t(), Date.t()) :: [String.t()]
  def expired_keys(table_name, %Date{} = cutoff) when is_binary(table_name) do
    require Ash.Query

    actor = SystemActor.system(:analytics_store)

    query =
      __MODULE__
      |> Ash.Query.filter(
        table_name == ^table_name and partition_date < ^cutoff and status == :published and
          is_nil(archive_batch_id) and not contains(object_key, "/_candidates/")
      )
      |> Ash.Query.select([:object_key, :staging_key])

    case Ash.read(query, actor: actor) do
      {:ok, rows} ->
        Enum.flat_map(rows, fn row ->
          [row.object_key | if(row.staging_key in [nil, ""], do: [], else: [row.staging_key])]
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Published files overlapping a UTC time window, read from the primary through Ash."
  @spec published_keys(String.t(), DateTime.t() | nil, DateTime.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def published_keys(table_name, start_time, end_time) do
    case Ash.read(published_query(table_name, start_time, end_time)) do
      {:ok, rows} -> {:ok, Enum.map(rows, & &1.object_key)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Manifest query with conservative overlap bounds; unknown file bounds remain visible."
  @spec published_query(String.t(), DateTime.t() | nil, DateTime.t() | nil) :: Ash.Query.t()
  def published_query(table_name, start_time, end_time) do
    require Ash.Query

    query =
      __MODULE__
      |> Ash.Query.for_read(:read, %{}, actor: SystemActor.system(:analytics_store))
      |> Ash.Query.filter(table_name == ^table_name and status == :published)
      |> Ash.Query.select([:object_key])
      |> Ash.Query.sort(object_key: :asc)

    query =
      if start_time do
        start_date = DateTime.to_date(start_time)

        Ash.Query.filter(
          query,
          partition_date >= ^start_date and
            (is_nil(max_timestamp) or max_timestamp >= ^start_time)
        )
      else
        query
      end

    if end_time do
      end_date = DateTime.to_date(end_time)

      Ash.Query.filter(
        query,
        partition_date <= ^end_date and
          (is_nil(min_timestamp) or min_timestamp <= ^end_time)
      )
    else
      query
    end
  end

  @doc "Drop a manifest row after its object has been deleted."
  @spec forget(String.t()) :: :ok
  def forget(object_key) when is_binary(object_key) do
    require Ash.Query

    actor = SystemActor.system(:analytics_store)

    query =
      Ash.Query.filter(
        __MODULE__,
        (object_key == ^object_key or staging_key == ^object_key) and
          status == :published and is_nil(archive_batch_id) and
          not contains(object_key, "/_candidates/")
      )

    _ =
      Ash.bulk_destroy(query, :destroy, %{},
        actor: actor,
        return_errors?: false,
        strategy: [:atomic, :stream]
      )

    :ok
  end
end
