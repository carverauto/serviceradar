defmodule ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation do
  @moduledoc """
  Latest Edge branch signal observation (`platform.declarative_check_edge_observations`)
  for Hybrid Edge + Core declarative checks (`1.3`, Decision 4).

  Keyed by `(check_id, node_id, target_key, agent_id)`. Read by `CoreEvaluationWorker`
  and `DecisionTableEvaluator` with per-input `max_age_seconds` staleness enforcement.
  """

  use Ash.Resource,
    domain: ServiceRadar.DeclarativeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @view_check {ActorHasPermission, permission: "declarative_checks.view"}
  @manage_check {ActorHasPermission, permission: "declarative_checks.manage"}
  @evaluate_check {ActorHasPermission, permission: "declarative_checks.evaluate"}

  @system_actor SystemActor.system(:declarative_check_edge_observations)

  @upsert_fields [
    :check_id,
    :node_id,
    :target_key,
    :device_uid,
    :agent_id,
    :status,
    :value,
    :payload,
    :duration_ms,
    :observed_at
  ]

  postgres do
    table "declarative_check_edge_observations"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_observation: "declarative_check_edge_observations_uidx"

    custom_indexes do
      index [:check_id, :target_key], name: "declarative_check_edge_observations_target_idx"

      index [:device_uid],
        name: "declarative_check_edge_observations_device_uid_idx",
        where: "device_uid IS NOT NULL"
    end

    references do
      reference :check,
        on_delete: :delete,
        name: "declarative_check_edge_observations_check_id_fkey"
    end

    check_constraints do
      check_constraint :payload, "declarative_check_edge_observations_valid",
        check: """
        btrim(node_id) <> '' AND
        btrim(target_key) <> '' AND
        btrim(agent_id) <> '' AND
        status IN ('healthy', 'degraded', 'down', 'unknown') AND
        octet_length(payload::text) <= 16384
        """
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :upsert_observation, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [observed_at: :desc])
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    create :upsert do
      primary? true
      accept @upsert_fields
      upsert? true
      upsert_identity :unique_observation

      upsert_fields [
        :device_uid,
        :status,
        :value,
        :payload,
        :duration_ms,
        :observed_at,
        :updated_at
      ]
    end

    update :reassign_device do
      accept [:device_uid, :target_key]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @evaluate_check
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :check_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :node_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :target_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :device_uid, :string do
      allow_nil? true
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :value, :string do
      allow_nil? true
      public? true
    end

    attribute :payload, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :duration_ms, :integer do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :check, DeclarativeCheck do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :check_id
    end
  end

  identities do
    identity :unique_observation, [:check_id, :node_id, :target_key, :agent_id]
  end

  @doc """
  Reassigns or deduplicates `DeclarativeCheckEdgeObservation` rows from `from_uid`
  onto `to_uid` during a DIRE device identity merge (`1.3`).
  """
  @spec reassign_device(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reassign_device(from_uid, to_uid, opts \\ [])
      when is_binary(from_uid) and is_binary(to_uid) and is_list(opts) do
    if from_uid == to_uid do
      :ok
    else
      actor = Keyword.get(opts, :actor, @system_actor)
      new_target_key = "device:#{to_uid}"

      case list_by_device(from_uid, actor: actor) do
        {:ok, rows} ->
          repoint_observations(rows, to_uid, new_target_key, actor)

        {:error, _} = err ->
          err
      end
    end
  end

  defp repoint_observations(rows, to_uid, new_target_key, actor) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      query =
        __MODULE__
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(
          check_id == ^row.check_id and node_id == ^row.node_id and
            target_key == ^new_target_key and agent_id == ^row.agent_id
        )

      case Ash.read_one(query, actor: actor) do
        {:ok, %{__struct__: __MODULE__}} ->
          case Ash.destroy(row, actor: actor) do
            :ok -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, err}}
          end

        _ ->
          row
          |> Ash.Changeset.for_update(:reassign_device, %{
            device_uid: to_uid,
            target_key: new_target_key
          })
          |> Ash.update(actor: actor)
          |> case do
            {:ok, _} -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, err}}
          end
      end
    end)
  end
end
