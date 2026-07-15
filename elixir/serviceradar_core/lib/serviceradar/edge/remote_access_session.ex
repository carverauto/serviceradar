defmodule ServiceRadar.Edge.RemoteAccessSession do
  @moduledoc """
  Persistent lifecycle record for generic agent-routed remote access sessions.

  Attach tickets are stored only as SHA-256 hashes. Session metadata is for
  target/routing/audit context and must not contain credential payloads.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  import Ash.Expr

  alias ServiceRadar.Edge.Checks.ActorCanCreateRemoteAccessProtocol
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @remote_access_ssh_permission "devices.remote_access.ssh.open"
  @remote_access_rdp_permission "devices.remote_access.rdp.open"
  @remote_access_ssh_check {ActorHasPermission, permission: @remote_access_ssh_permission}
  @remote_access_rdp_check {ActorHasPermission, permission: @remote_access_rdp_permission}

  @create_fields [
    :attach_ticket_hash,
    :attach_expires_at,
    :device_uid,
    :target_kind,
    :target_host,
    :target_port,
    :protocol,
    :adapter,
    :agent_id,
    :gateway_id,
    :credential_custody_mode,
    :credential_rule_id,
    :requested_by,
    :approval_id,
    :rbac_decision,
    :idle_timeout_seconds,
    :absolute_timeout_seconds,
    :recording_policy,
    :enhanced_recording_policy,
    :metadata
  ]

  postgres do
    table "remote_access_sessions"
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
    table_name "remote_access_session_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    create_version_on_destroy? false
    ignore_attributes [:attach_ticket_hash, :last_activity_at, :inserted_at, :updated_at]
    ignore_actions [:record_activity]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_attach_ticket_hash, action: :by_attach_ticket_hash, args: [:attach_ticket_hash]
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

    read :by_attach_ticket_hash do
      argument :attach_ticket_hash, :string, allow_nil?: false
      get? true

      filter expr(
               attach_ticket_hash == ^arg(:attach_ticket_hash) and status == :requested and
                 attach_expires_at > now()
             )
    end

    create :create do
      accept @create_fields
    end

    update :attach do
      change transition_state(:attached)
      change set_attribute(:attached_at, &__MODULE__.utc_now/0)
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
      accept [:close_reason, :outcome]
      change transition_state(:closing)
      change set_attribute(:close_requested_at, &__MODULE__.utc_now/0)
    end

    update :close do
      accept [:close_reason, :outcome]
      change transition_state(:closed)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end

    update :fail do
      accept [:failure_reason, :close_reason, :outcome]
      change transition_state(:failed)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end

    update :expire do
      accept [:close_reason, :outcome]
      change transition_state(:expired)
      change set_attribute(:closed_at, &__MODULE__.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @remote_access_ssh_check
      authorize_if @remote_access_rdp_check
    end

    policy action_type(:create) do
      authorize_if ActorCanCreateRemoteAccessProtocol
    end

    policy action_type([:update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :attach_ticket_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :attach_expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :attached_at, :utc_datetime do
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
      public? true
    end

    attribute :target_kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :inventory_device,
                    :provider_console,
                    :freeform_target,
                    :registered_application_target,
                    :registered_tcp_target
                  ]

      default :inventory_device
    end

    attribute :target_host, :string do
      allow_nil? false
      public? true
    end

    attribute :target_port, :integer do
      allow_nil? false
      public? true
      default 22
      constraints min: 1, max: 65_535
    end

    attribute :protocol, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :ssh,
                    :proxmox_console,
                    :vsphere_console,
                    :rdp,
                    :app,
                    :tcp,
                    :database,
                    :kubernetes,
                    :desktop,
                    :ot
                  ]
    end

    attribute :adapter, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :ssh,
                    :proxmox_console,
                    :vsphere_console,
                    :rdp,
                    :app,
                    :application,
                    :tcp,
                    :database,
                    :kubernetes,
                    :desktop,
                    :ot
                  ]
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :credential_custody_mode, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :ssh_certificate,
                    :user_present,
                    :centrally_brokered,
                    :provider_ticket,
                    :none
                  ]
    end

    attribute :credential_rule_id, :uuid do
      public? true
    end

    attribute :requested_by, :uuid do
      public? true
    end

    attribute :approval_id, :uuid do
      public? true
    end

    attribute :rbac_decision, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:allowed, :denied, :approval_required]
      default :allowed
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

    attribute :outcome, :atom do
      public? true

      constraints one_of: [
                    :completed,
                    :idle_timeout,
                    :absolute_timeout,
                    :agent_disconnected,
                    :target_unreachable,
                    :credential_rejected,
                    :credential_policy_denied,
                    :rbac_denied,
                    :protocol_error,
                    :internal_error
                  ]
    end

    attribute :recording_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :enhanced_recording_policy, :map do
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

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      public? true
      define_attribute? false
    end

    belongs_to :credential_rule, ServiceRadar.Credentials.NetworkCredentialRule do
      source_attribute :credential_rule_id
      public? true
      define_attribute? false
    end

    has_one :recording, ServiceRadar.Edge.RemoteAccessRecording do
      source_attribute :id
      destination_attribute :session_id
      public? true
    end

    has_many :file_transfers, ServiceRadar.Edge.RemoteAccessFileTransfer do
      source_attribute :id
      destination_attribute :session_id
      public? true
    end
  end

  identities do
    identity :unique_attach_ticket_hash, [:attach_ticket_hash]
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
