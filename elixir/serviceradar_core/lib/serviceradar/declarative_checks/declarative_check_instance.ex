defmodule ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance do
  @moduledoc """
  Materialized per-target declarative check verdict (`platform.declarative_check_instances`, `1.3`).

  Supports `singleton` (`"singleton"`), `srql_devices` (`"device:<device_uid>"`),
  and `service_targets` (`"service:<service_target_id>"`) under one uniform model,
  recording `changed_at` strictly on verdict/status transitions, bounding
  `node_snapshots` to `<= 16 KB` redacted JSONB, and handling DIRE device merges
  via `reassign_device_instances/3`.
  """

  use Ash.Resource,
    domain: ServiceRadar.DeclarativeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.ServiceStateProjector
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @view_check {ActorHasPermission, permission: "declarative_checks.view"}
  @manage_check {ActorHasPermission, permission: "declarative_checks.manage"}
  @evaluate_check {ActorHasPermission, permission: "declarative_checks.evaluate"}

  @system_actor SystemActor.system(:declarative_check_instances)

  @upsert_fields [
    :check_id,
    :target_key,
    :target_kind,
    :device_uid,
    :service_target_id,
    :verdict,
    :status,
    :summary,
    :node_snapshots,
    :evaluated_at,
    :changed_at
  ]

  postgres do
    table "declarative_check_instances"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_check_target: "declarative_check_instances_check_target_uidx"

    custom_indexes do
      index [:device_uid],
        name: "declarative_check_instances_device_uid_idx",
        where: "device_uid IS NOT NULL"

      index [:check_id, :status], name: "declarative_check_instances_check_status_idx"
      index [:check_id, :evaluated_at], name: "declarative_check_instances_check_eval_idx"
    end

    references do
      reference :check,
        on_delete: :delete,
        name: "declarative_check_instances_check_id_fkey"
    end

    check_constraints do
      check_constraint :node_snapshots, "declarative_check_instances_snapshot_bounded",
        check: """
        btrim(target_key) <> '' AND
        target_kind IN ('singleton', 'device', 'service_target') AND
        status IN ('healthy', 'degraded', 'down', 'unknown') AND
        octet_length(node_snapshots::text) <= 16384
        """
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :get_by_check_target, action: :by_check_target, args: [:check_id, :target_key]
    define :upsert_instance, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [target_key: :asc])
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [evaluated_at: :desc])
    end

    read :by_check_target do
      argument :check_id, :uuid, allow_nil?: false
      argument :target_key, :string, allow_nil?: false
      get? true
      filter expr(check_id == ^arg(:check_id) and target_key == ^arg(:target_key))
    end

    create :upsert do
      primary? true
      accept @upsert_fields
      upsert? true
      upsert_identity :unique_check_target

      upsert_fields [
        :target_kind,
        :device_uid,
        :service_target_id,
        :verdict,
        :status,
        :summary,
        :node_snapshots,
        :evaluated_at,
        :changed_at,
        :updated_at
      ]
    end

    update :reassign_device do
      description "Repoints a device-scoped instance onto the surviving canonical device UID during DIRE merges"
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

    attribute :target_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :target_kind, :atom do
      allow_nil? false
      default :singleton
      public? true
      constraints one_of: [:singleton, :device, :service_target]
    end

    attribute :device_uid, :string do
      allow_nil? true
      public? true
    end

    attribute :service_target_id, :string do
      allow_nil? true
      public? true
    end

    attribute :verdict, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :summary, :string do
      allow_nil? true
      public? true
      constraints max_length: 512
    end

    attribute :node_snapshots, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :evaluated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :changed_at, :utc_datetime_usec do
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
    identity :unique_check_target, [:check_id, :target_key]
  end

  @doc """
  Reassigns or deduplicates `DeclarativeCheckInstance` rows from `from_uid` onto
  `to_uid` during a DIRE device identity merge (`1.3`).
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
          repoint_or_drop_rows(rows, to_uid, new_target_key, actor, opts)

        {:error, _} = err ->
          err
      end
    end
  end

  defp repoint_or_drop_rows(rows, to_uid, new_target_key, actor, opts) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      maybe_deactivate_old_service_state(row, actor, opts)

      case get_by_check_target(row.check_id, new_target_key, actor: actor) do
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
            {:ok, updated} ->
              maybe_project_new_service_state(updated, actor, opts)
              {:cont, :ok}

            {:error, err} ->
              {:halt, {:error, err}}
          end
      end
    end)
  end

  defp maybe_deactivate_old_service_state(row, actor, opts) do
    case Ash.get(DeclarativeCheck, row.check_id, actor: actor, not_found_error?: false) do
      {:ok, %{slug: slug}} ->
        ServiceStateProjector.deactivate_targets(slug, [row.target_key], opts)

      _ ->
        :ok
    end
  end

  defp maybe_project_new_service_state(row, actor, opts) do
    case Ash.get(DeclarativeCheck, row.check_id, actor: actor, not_found_error?: false) do
      {:ok, %{state: :enabled} = check} ->
        _ = ServiceStateProjector.project_instance(check, row, opts)
        :ok

      _ ->
        :ok
    end
  end
end
