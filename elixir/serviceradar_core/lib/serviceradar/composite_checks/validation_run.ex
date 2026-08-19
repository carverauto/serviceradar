defmodule ServiceRadar.CompositeChecks.ValidationRun do
  @moduledoc """
  One NCO-driven composite-check validation.

  Identity is resolved before insert. Probe dispatch and evaluation happen
  asynchronously via `ValidationRunWorker`.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @execute_check {ActorHasPermission, permission: "validation_runs.execute"}
  @read_check {ActorHasPermission, permission: "validation_runs.read"}

  @statuses [:pending, :probing, :evaluating, :completed, :failed, :timed_out]

  @create_fields [:check_id, :check_slug, :deadline_at, :requested_by, :status]
  @update_fields [:status, :error, :scan_run_ids]

  postgres do
    table "validation_runs"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete
    end

    custom_indexes do
      index [:status], name: "validation_runs_status_idx"
      index [:inserted_at], name: "validation_runs_inserted_at_idx"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_recent, action: :recent
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:devices, :check])
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], load: [:devices], limit: 100)
    end

    create :create do
      accept @create_fields
      change set_attribute(:status, :pending)
    end

    update :update do
      accept @update_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@read_check)
    action_type_with_permission([:create, :update, :destroy], @execute_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :check_slug, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: @statuses
    end

    attribute :deadline_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :scan_run_ids, {:array, :uuid} do
      allow_nil? false
      default []
      public? true
    end

    attribute :requested_by, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end

    has_many :devices, ServiceRadar.CompositeChecks.ValidationRunDevice do
      destination_attribute :run_id
      public? true
    end
  end
end
