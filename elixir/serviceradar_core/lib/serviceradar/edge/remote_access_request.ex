defmodule ServiceRadar.Edge.RemoteAccessRequest do
  @moduledoc """
  Access-request lifecycle for approval-gated remote-access sessions.

  Requests are approval policy records only. They do not store credentials or
  attach tickets; an approved request can be bound to exactly one session.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Policies.Checks.ActorSelfApprovesResource

  @ssh_open_permission "devices.remote_access.ssh.open"
  @rdp_open_permission "devices.remote_access.rdp.open"
  @app_open_permission "devices.remote_access.app.open"
  @tcp_open_permission "devices.remote_access.tcp.open"
  @review_permission "devices.remote_access.requests.review"
  @ssh_open_check {ActorHasPermission, permission: @ssh_open_permission}
  @rdp_open_check {ActorHasPermission, permission: @rdp_open_permission}
  @app_open_check {ActorHasPermission, permission: @app_open_permission}
  @tcp_open_check {ActorHasPermission, permission: @tcp_open_permission}
  @review_check {ActorHasPermission, permission: @review_permission}

  @create_fields [
    :requested_by,
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
    :reason,
    :expires_at,
    :reviewer_policy,
    :metadata
  ]

  postgres do
    table "remote_access_requests"
    repo ServiceRadar.Repo
    schema "platform"
    identity_wheres_to_sql unique_bound_session: "session_id IS NOT NULL"
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      transition :approve, from: :pending, to: :approved
      transition :deny, from: :pending, to: :denied
      transition :expire, from: [:pending, :approved], to: :expired
      transition :bind_session, from: :approved, to: :consumed
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "remote_access_request_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :create_request, action: :create
    define :approve, action: :approve
    define :deny, action: :deny
    define :expire, action: :expire
    define :bind_session, action: :bind_session
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept @create_fields
    end

    update :approve do
      accept [:approved_by, :approved_at, :review_note]
      change transition_state(:approved)
    end

    update :deny do
      accept [:denied_by, :denied_at, :denial_reason, :review_note]
      change transition_state(:denied)
    end

    update :expire do
      accept [:expired_at]
      change transition_state(:expired)
    end

    update :bind_session do
      accept [:session_id, :bound_at]
      change transition_state(:consumed)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @ssh_open_check
      authorize_if @rdp_open_check
      authorize_if @app_open_check
      authorize_if @tcp_open_check
      authorize_if @review_check
    end

    policy action_type(:create) do
      authorize_if @ssh_open_check
      authorize_if @rdp_open_check
      authorize_if @app_open_check
      authorize_if @tcp_open_check
    end

    action_with_permission(:deny, @review_check)

    policy action(:approve) do
      forbid_if {ActorSelfApprovesResource,
                 requester_attribute: :requested_by, approver_attribute: :approved_by}

      authorize_if @review_check
    end

    policy action([:expire, :bind_session]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :denied, :expired, :consumed]
    end

    attribute :requested_by, :uuid do
      allow_nil? false
      public? true
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      default :inventory_device
      constraints one_of: [:inventory_device, :provider_console, :freeform_target]
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

    attribute :reason, :string do
      public? true
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :approved_by, :uuid do
      public? true
    end

    attribute :approved_at, :utc_datetime do
      public? true
    end

    attribute :denied_by, :uuid do
      public? true
    end

    attribute :denied_at, :utc_datetime do
      public? true
    end

    attribute :denial_reason, :string do
      public? true
    end

    attribute :review_note, :string do
      public? true
    end

    attribute :expired_at, :utc_datetime do
      public? true
    end

    attribute :session_id, :uuid do
      public? true
    end

    attribute :bound_at, :utc_datetime do
      public? true
    end

    attribute :reviewer_policy, :map do
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
    belongs_to :session, ServiceRadar.Edge.RemoteAccessSession do
      source_attribute :session_id
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_bound_session, [:session_id], where: expr(not is_nil(session_id))
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
