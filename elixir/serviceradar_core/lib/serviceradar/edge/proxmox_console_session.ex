defmodule ServiceRadar.Edge.ProxmoxConsoleSession do
  @moduledoc """
  Persistent lifecycle record for a Proxmox browser console session.

  The plaintext browser ticket is never stored. `ticket_hash` is used only for
  one-time websocket attachment and is excluded from PaperTrail changes.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @console_permission "devices.console.open"
  @console_check {ActorHasPermission, permission: @console_permission}
  @credential_use_permission "devices.console.credentials.use"
  @credential_use_check {ActorHasPermission, permission: @credential_use_permission}

  @create_fields [
    :ticket_hash,
    :ticket_expires_at,
    :device_uid,
    :target_kind,
    :console_mode,
    :agent_id,
    :gateway_id,
    :credential_rule_id,
    :requested_by,
    :idle_timeout_seconds,
    :absolute_timeout_seconds,
    :metadata
  ]

  postgres do
    table "proxmox_console_sessions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:requested]
    default_initial_state :requested
    state_attribute :status

    transitions do
      transition :attach, from: :requested, to: :attached
      transition :mark_opening, from: [:requested, :attached], to: :opening
      transition :activate, from: [:attached, :opening], to: :active
      transition :request_close, from: [:requested, :attached, :opening, :active], to: :closing
      transition :close, from: [:requested, :attached, :opening, :active, :closing], to: :closed
      transition :fail, from: [:requested, :attached, :opening, :active, :closing], to: :failed
      transition :expire, from: [:requested, :attached, :opening, :active], to: :expired
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "proxmox_console_session_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:ticket_hash, :inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_ticket_hash, action: :by_ticket_hash, args: [:ticket_hash]
    define :create_session, action: :create
    define :attach, action: :attach
    define :mark_opening, action: :mark_opening
    define :activate, action: :activate
    define :record_activity, action: :record_activity
    define :request_close, action: :request_close
    define :close, action: :close
    define :fail_session, action: :fail
    define :expire, action: :expire
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_ticket_hash do
      argument :ticket_hash, :string, allow_nil?: false
      get? true

      filter expr(
               ticket_hash == ^arg(:ticket_hash) and status == :requested and
                 ticket_expires_at > now()
             )
    end

    create :create do
      accept @create_fields
    end

    update :attach do
      change transition_state(:attached)
      change set_attribute(:ticket_used_at, &__MODULE__.utc_now/0)
      change set_attribute(:last_activity_at, &__MODULE__.utc_now/0)
    end

    update :mark_opening do
      accept [:command_id]
      change transition_state(:opening)
    end

    update :activate do
      change transition_state(:active)
      change set_attribute(:opened_at, &__MODULE__.utc_now/0)
      change set_attribute(:last_activity_at, &__MODULE__.utc_now/0)
    end

    update :record_activity do
      change set_attribute(:last_activity_at, &__MODULE__.utc_now/0)
    end

    update :request_close do
      accept [:close_reason]
      change transition_state(:closing)
      change set_attribute(:close_requested_at, &__MODULE__.utc_now/0)
    end

    update :close do
      accept [:close_reason]
      change transition_state(:closed)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end

    update :fail do
      accept [:failure_reason, :close_reason]
      change transition_state(:failed)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end

    update :expire do
      accept [:close_reason]
      change transition_state(:expired)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@console_check)
    read_with_permission(@credential_use_check)
    action_type_with_permission(:create, @console_check)
    action_type_with_permission(:create, @credential_use_check)

    policy action_type([:update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :ticket_expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :ticket_used_at, :utc_datetime do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :requested,
                    :attached,
                    :opening,
                    :active,
                    :closing,
                    :closed,
                    :failed,
                    :expired
                  ]

      default :requested
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pve_host, :qemu_guest, :lxc_guest]
    end

    attribute :console_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ssh, :proxmox_termproxy, :proxmox_vncwebsocket]
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :credential_rule_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :requested_by, :uuid do
      allow_nil? false
      public? true
    end

    attribute :command_id, :uuid do
      public? true
    end

    attribute :idle_timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 900
      constraints min: 1
    end

    attribute :absolute_timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 3600
      constraints min: 1
    end

    attribute :opened_at, :utc_datetime do
      public? true
    end

    attribute :last_activity_at, :utc_datetime do
      public? true
    end

    attribute :close_requested_at, :utc_datetime do
      public? true
    end

    attribute :closed_at, :utc_datetime do
      public? true
    end

    attribute :close_reason, :string do
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? false
      public? true
      define_attribute? false
    end

    belongs_to :credential_rule, ServiceRadar.Credentials.NetworkCredentialRule do
      source_attribute :credential_rule_id
      allow_nil? false
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_ticket_hash, [:ticket_hash]
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
