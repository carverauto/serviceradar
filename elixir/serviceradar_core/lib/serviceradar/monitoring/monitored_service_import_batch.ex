defmodule ServiceRadar.Monitoring.MonitoredServiceImportBatch do
  @moduledoc """
  Auditable lifecycle record for bulk service target imports.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_create_check {ActorHasPermission, permission: "services.create"}
  @services_update_check {ActorHasPermission, permission: "services.update"}

  @fields [
    :source_type,
    :filename,
    :total_rows,
    :valid_rows,
    :invalid_rows,
    :duplicate_rows,
    :created_by_actor_id,
    :validation_errors,
    :metadata
  ]

  postgres do
    table "monitored_service_import_batches"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :status

    transitions do
      transition :start_validation, from: [:draft], to: :validating
      transition :mark_validated, from: [:validating], to: :validated
      transition :mark_failed, from: [:draft, :validating, :validated], to: :failed
      transition :commit, from: [:validated], to: :committed
      transition :cancel, from: [:draft, :validating, :validated], to: :cancelled
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "monitored_service_import_batch_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_status, action: :by_status, args: [:status]
    define :create_batch, action: :create
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_status do
      argument :status, :atom do
        allow_nil? false
        constraints one_of: [:draft, :validating, :validated, :committed, :failed, :cancelled]
      end

      filter expr(status == ^arg(:status))
    end

    create :create do
      accept @fields
    end

    update :update do
      accept @fields
    end

    update :start_validation do
      accept [:metadata]
      change transition_state(:validating)
    end

    update :mark_validated do
      accept [
        :total_rows,
        :valid_rows,
        :invalid_rows,
        :duplicate_rows,
        :validation_errors,
        :metadata
      ]

      change transition_state(:validated)
    end

    update :mark_failed do
      accept [:validation_errors, :metadata]
      change transition_state(:failed)
    end

    update :commit do
      accept [:metadata]
      change transition_state(:committed)
    end

    update :cancel do
      accept [:metadata]
      change transition_state(:cancelled)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_type_with_permission(:create, @services_create_check)

    action_with_permission(
      [:update, :start_validation, :mark_validated, :mark_failed, :commit, :cancel],
      @services_update_check
    )
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :csv_upload
      constraints one_of: [:paste, :csv_upload, :api, :discovery, :backfill]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :validating, :validated, :committed, :failed, :cancelled]
    end

    attribute :filename, :string, allow_nil?: true, public?: true

    attribute :total_rows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :valid_rows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :invalid_rows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :duplicate_rows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :created_by_actor_id, :string, allow_nil?: true, public?: true

    attribute :validation_errors, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
