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
        :content_checksum,
        :batch_id,
        :status
      ]

      upsert? true
      upsert_identity :object_key
    end
  end

  attributes do
    integer_primary_key :id, writable?: false, generated?: true

    attribute :table_name, :string, allow_nil?: false
    attribute :object_key, :string, allow_nil?: false
    attribute :staging_key, :string, allow_nil?: false
    attribute :partition_date, :date, allow_nil?: false
    attribute :row_count, :integer
    attribute :content_checksum, :string
    attribute :batch_id, :string, allow_nil?: false

    attribute :status, :atom,
      allow_nil?: false,
      default: :published,
      constraints: [one_of: [:pending, :verified, :published]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :object_key, [:object_key]
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

  @doc "Published object keys whose partition_date is strictly before `cutoff`."
  @spec expired_keys(String.t(), Date.t()) :: [String.t()]
  def expired_keys(table_name, %Date{} = cutoff) when is_binary(table_name) do
    require Ash.Query

    actor = SystemActor.system(:analytics_store)

    query =
      __MODULE__
      |> Ash.Query.filter(
        table_name == ^table_name and partition_date < ^cutoff and status == :published
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

  @doc "Drop a manifest row after its object has been deleted."
  @spec forget(String.t()) :: :ok
  def forget(object_key) when is_binary(object_key) do
    require Ash.Query

    actor = SystemActor.system(:analytics_store)

    query = Ash.Query.filter(__MODULE__, object_key == ^object_key or staging_key == ^object_key)

    _ =
      Ash.bulk_destroy(query, :destroy, %{},
        actor: actor,
        return_errors?: false,
        strategy: [:atomic, :stream]
      )

    :ok
  end
end
