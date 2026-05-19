defmodule ServiceRadar.Automation.Northbound.ActionInvocation do
  @moduledoc """
  Persisted execution request for a northbound action.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Northbound.Changes.RedactInvocationInput
  alias ServiceRadar.Automation.Northbound.Changes.RedactInvocationResult
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}
  @launch_check {ActorHasPermission, permission: "northbound.actions.launch"}
  @cancel_check {ActorHasPermission, permission: "northbound.actions.cancel"}

  @fields [
    :provider_id,
    :descriptor_id,
    :action_id,
    :action_version,
    :descriptor_hash,
    :source,
    :requested_by_actor_id,
    :event_handler_id,
    :originating_event_id,
    :target_snapshots,
    :input_values,
    :redacted_input_values,
    :state,
    :started_at,
    :completed_at,
    :result_summary,
    :external_correlation_id,
    :error_class,
    :error_message,
    :metadata
  ]

  postgres do
    table "northbound_action_invocations"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :provider, on_delete: :nilify
      reference :descriptor, on_delete: :nilify
      reference :event_handler, on_delete: :nilify
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :state

    transitions do
      transition :record_dispatch, from: :pending, to: :dispatching
      transition :record_running, from: [:pending, :dispatching], to: :running

      transition :record_polling,
        from: [:dispatching, :running, :polling, :result_fetching],
        to: :polling

      transition :record_result_fetching,
        from: [:running, :polling, :result_fetching],
        to: :result_fetching

      transition :record_succeeded,
        from: [:dispatching, :running, :polling, :result_fetching],
        to: :succeeded

      transition :record_failed,
        from: [:pending, :dispatching, :running, :polling, :result_fetching],
        to: :failed

      transition :record_expired,
        from: [:pending, :dispatching, :running, :polling, :result_fetching],
        to: :expired

      transition :record_canceled,
        from: [:pending, :dispatching, :running, :polling, :result_fetching],
        to: :canceled

      transition :record_suppressed, from: :pending, to: :suppressed
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "northbound_action_invocation_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :input_values]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_recent, action: :recent
    define :list_by_target, action: :by_target, args: [:target_kind, :target_id]
    define :create_invocation, action: :create
    define :record_dispatch, action: :record_dispatch
    define :record_running, action: :record_running
    define :record_polling, action: :record_polling
    define :record_result_fetching, action: :record_result_fetching
    define :record_succeeded, action: :record_succeeded
    define :record_failed, action: :record_failed
    define :record_expired, action: :record_expired
    define :record_canceled, action: :record_canceled
    define :record_suppressed, action: :record_suppressed
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))

      prepare build(
                load: [:provider, :descriptor, :targets],
                select: [:id, :inserted_at, :updated_at | @fields]
              )
    end

    read :recent do
      prepare build(
                sort: [inserted_at: :desc],
                select: [:id, :inserted_at, :updated_at | @fields]
              )
    end

    read :by_target do
      argument :target_kind, :string, allow_nil?: false
      argument :target_id, :string, allow_nil?: false

      filter expr(
               fragment(
                 """
                 EXISTS (
                   SELECT 1
                   FROM unnest(?) AS target
                   WHERE target->>'kind' = ?
                     AND (
                       target->>'device_uid' = ?
                       OR target->>'interface_uid' = ?
                       OR target->>'event_id' = ?
                     )
                 )
                 """,
                 target_snapshots,
                 ^arg(:target_kind),
                 ^arg(:target_id),
                 ^arg(:target_id),
                 ^arg(:target_id)
               )
             )

      prepare build(
                load: [:provider, :descriptor],
                sort: [inserted_at: :desc],
                select: [:id, :inserted_at, :updated_at | @fields]
              )
    end

    create :create do
      accept [
        :provider_id,
        :descriptor_id,
        :action_id,
        :action_version,
        :descriptor_hash,
        :source,
        :requested_by_actor_id,
        :event_handler_id,
        :originating_event_id,
        :target_snapshots,
        :input_values,
        :redacted_input_values,
        :metadata
      ]

      change RedactInvocationInput
    end

    update :record_dispatch do
      accept [:metadata]
      change transition_state(:dispatching)
    end

    update :record_running do
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:running)
    end

    update :record_polling do
      accept [:result_summary, :external_correlation_id]
      change RedactInvocationResult
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:polling)
    end

    update :record_result_fetching do
      accept [:result_summary, :external_correlation_id]
      change RedactInvocationResult
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:result_fetching)
    end

    update :record_succeeded do
      accept [:result_summary, :external_correlation_id]
      change RedactInvocationResult
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:succeeded)
    end

    update :record_failed do
      accept [:result_summary, :external_correlation_id, :error_class, :error_message]
      change RedactInvocationResult
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:failed)
    end

    update :record_expired do
      accept [:result_summary, :external_correlation_id, :error_class, :error_message]
      change RedactInvocationResult
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:expired)
    end

    update :record_canceled do
      accept [:result_summary]
      change RedactInvocationResult
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:canceled)
    end

    update :record_suppressed do
      accept [:result_summary, :error_class, :error_message]
      change RedactInvocationResult
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:suppressed)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :recent, :by_target], @view_check)
    action_with_permission([:create], @launch_check)
    action_with_permission([:record_canceled], @cancel_check)
    # Dispatch/running/success/failure/suppression are system driven.
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_id, :uuid, allow_nil?: true, public?: true
    attribute :descriptor_id, :uuid, allow_nil?: true, public?: true
    attribute :action_id, :string, allow_nil?: false, public?: true
    attribute :action_version, :string, allow_nil?: false, public?: true, default: "1.0.0"
    attribute :descriptor_hash, :string, allow_nil?: true, public?: true

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :user
      constraints one_of: [:user, :schedule, :event_handler, :system]
    end

    attribute :requested_by_actor_id, :uuid, allow_nil?: true, public?: true
    attribute :event_handler_id, :uuid, allow_nil?: true, public?: true
    attribute :originating_event_id, :string, allow_nil?: true, public?: true

    attribute :target_snapshots, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :input_values, :map do
      allow_nil? false
      public? false
      sensitive? true
      default %{}
    end

    attribute :redacted_input_values, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :dispatching,
                    :running,
                    :polling,
                    :result_fetching,
                    :succeeded,
                    :failed,
                    :expired,
                    :canceled,
                    :suppressed
                  ]
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :completed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :result_summary, :map, allow_nil?: false, public?: true, default: %{}
    attribute :external_correlation_id, :string, allow_nil?: true, public?: true
    attribute :error_class, :string, allow_nil?: true, public?: true
    attribute :error_message, :string, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :provider, ServiceRadar.Automation.Northbound.ActionProvider do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :provider_id
    end

    belongs_to :descriptor, ServiceRadar.Automation.Northbound.ActionDescriptor do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :descriptor_id
    end

    belongs_to :event_handler, ServiceRadar.Automation.Northbound.ActionEventHandler do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :event_handler_id
    end

    has_many :targets, ServiceRadar.Automation.Northbound.ActionInvocationTarget do
      destination_attribute :invocation_id
    end
  end
end
