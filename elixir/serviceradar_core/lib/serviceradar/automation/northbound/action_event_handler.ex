defmodule ServiceRadar.Automation.Northbound.ActionEventHandler do
  @moduledoc """
  Event-to-action handler configuration.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}
  @manage_check {ActorHasPermission, permission: "northbound.event_handlers.manage"}

  @fields [
    :name,
    :description,
    :state,
    :descriptor_id,
    :match_expression,
    :target_resolver,
    :input_template,
    :dedupe_key_template,
    :cooldown_seconds,
    :rate_limit,
    :approval_mode,
    :service_principal,
    :last_triggered_at,
    :metadata
  ]

  postgres do
    table "northbound_action_event_handlers"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :descriptor, on_delete: :restrict
    end
  end

  state_machine do
    initial_states [:disabled]
    default_initial_state :disabled
    state_attribute :state

    transitions do
      transition :enable, from: :disabled, to: :enabled
      transition :disable, from: :enabled, to: :disabled
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "northbound_action_event_handler_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :last_triggered_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :create_handler, action: :create
    define :update_handler, action: :update
    define :enable, action: :enable
    define :disable, action: :disable
    define :record_triggered, action: :record_triggered
  end

  actions do
    defaults [:destroy]

    read :read do
      prepare build(load: [:descriptor], select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:descriptor], select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :enabled do
      filter expr(state == :enabled)
      prepare build(load: [:descriptor], select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :create do
      accept List.delete(@fields, :state)
    end

    update :update do
      accept [
        :name,
        :description,
        :descriptor_id,
        :match_expression,
        :target_resolver,
        :input_template,
        :dedupe_key_template,
        :cooldown_seconds,
        :rate_limit,
        :approval_mode,
        :service_principal,
        :metadata
      ]
    end

    update :enable do
      change transition_state(:enabled)
    end

    update :disable do
      change transition_state(:disabled)
    end

    update :record_triggered do
      accept [:metadata]
      change set_attribute(:last_triggered_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :enabled], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:enable, :disable, :record_triggered], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :disabled
      constraints one_of: [:disabled, :enabled]
    end

    attribute :descriptor_id, :uuid, allow_nil?: false, public?: true

    attribute :match_expression, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :target_resolver, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :input_template, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :dedupe_key_template, :string, allow_nil?: true, public?: true

    attribute :cooldown_seconds, :integer do
      allow_nil? false
      public? true
      default 300
      constraints min: 0
    end

    attribute :rate_limit, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :approval_mode, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :automatic, :dry_run]
    end

    attribute :service_principal, :string do
      allow_nil? false
      public? true
      default "northbound-event-handler"
    end

    attribute :last_triggered_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :descriptor, ServiceRadar.Automation.Northbound.ActionDescriptor do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :descriptor_id
    end

    has_many :invocations, ServiceRadar.Automation.Northbound.ActionInvocation do
      destination_attribute :event_handler_id
    end
  end
end
