defmodule ServiceRadar.Edge.RemoteAccessHostKey do
  @moduledoc """
  Persistent SSH host-key trust state for agent-routed remote access.

  These records describe target host keys observed by trusted agent-side
  adapters. They are policy state and audit context only; no user or target
  login credentials are stored here.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_permission "settings.remote_access_host_keys.manage"
  @manage_check {ActorHasPermission, permission: @manage_permission}

  @create_fields [
    :device_uid,
    :target_host,
    :target_port,
    :protocol,
    :agent_id,
    :gateway_id,
    :key_type,
    :fingerprint_sha256,
    :public_key,
    :status,
    :source,
    :first_seen_at,
    :last_seen_at,
    :seen_count,
    :trusted_at,
    :trusted_by,
    :supersedes_host_key_id,
    :metadata
  ]

  postgres do
    table "remote_access_host_keys"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "remote_access_host_key_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_by_target_fingerprint,
      action: :by_target_fingerprint,
      args: [:agent_id, :target_host, :target_port, :protocol, :fingerprint_sha256]

    define :list_for_target,
      action: :for_target,
      args: [:agent_id, :target_host, :target_port, :protocol]

    define :create_host_key, action: :create
    define :record_seen, action: :record_seen
    define :trust, action: :trust
    define :mark_conflict, action: :mark_conflict
    define :reject, action: :reject
    define :revoke, action: :revoke
    define :mark_rotated, action: :mark_rotated
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_target_fingerprint do
      argument :agent_id, :string, allow_nil?: false
      argument :target_host, :string, allow_nil?: false
      argument :target_port, :integer, allow_nil?: false
      argument :protocol, :atom, allow_nil?: false
      argument :fingerprint_sha256, :string, allow_nil?: false
      get? true

      filter expr(
               agent_id == ^arg(:agent_id) and target_host == ^arg(:target_host) and
                 target_port == ^arg(:target_port) and protocol == ^arg(:protocol) and
                 fingerprint_sha256 == ^arg(:fingerprint_sha256)
             )
    end

    read :for_target do
      argument :agent_id, :string, allow_nil?: false
      argument :target_host, :string, allow_nil?: false
      argument :target_port, :integer, allow_nil?: false
      argument :protocol, :atom, allow_nil?: false

      filter expr(
               agent_id == ^arg(:agent_id) and target_host == ^arg(:target_host) and
                 target_port == ^arg(:target_port) and protocol == ^arg(:protocol)
             )

      prepare build(sort: [status: :asc, last_seen_at: :desc, inserted_at: :desc])
    end

    create :create do
      accept @create_fields
    end

    update :record_seen do
      accept [:last_seen_at, :seen_count, :metadata]
    end

    update :trust do
      accept [:trusted_at, :trusted_by, :supersedes_host_key_id, :metadata]
      change set_attribute(:status, :trusted)
    end

    update :mark_conflict do
      accept [:last_seen_at, :seen_count, :metadata]
      change set_attribute(:status, :conflict)
    end

    update :revoke do
      accept [:revoked_at, :revoked_by, :revocation_reason, :metadata]
      change set_attribute(:status, :revoked)
    end

    update :reject do
      accept [:rejected_at, :rejected_by, :rejection_reason, :metadata]
      change set_attribute(:status, :rejected)
    end

    update :mark_rotated do
      accept [:rotated_at, :rotated_by, :replacement_host_key_id, :rotation_reason, :metadata]
      change set_attribute(:status, :rotated)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@manage_check)
    action_type_with_permission([:create, :update], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :device_uid, :string do
      public? true
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
      default :ssh
      constraints one_of: [:ssh]
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :key_type, :string do
      allow_nil? false
      public? true
    end

    attribute :fingerprint_sha256, :string do
      allow_nil? false
      public? true
    end

    attribute :public_key, :string do
      public? true
      sensitive? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :trusted, :conflict, :rotated, :revoked, :rejected]
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :agent_observed
      constraints one_of: [:agent_observed, :known_hosts, :trust_on_first_use, :manual]
    end

    attribute :first_seen_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :seen_count, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :trusted_at, :utc_datetime do
      public? true
    end

    attribute :trusted_by, :string do
      public? true
    end

    attribute :revoked_at, :utc_datetime do
      public? true
    end

    attribute :revoked_by, :string do
      public? true
    end

    attribute :revocation_reason, :string do
      public? true
    end

    attribute :rejected_at, :utc_datetime do
      public? true
    end

    attribute :rejected_by, :string do
      public? true
    end

    attribute :rejection_reason, :string do
      public? true
    end

    attribute :rotated_at, :utc_datetime do
      public? true
    end

    attribute :rotated_by, :string do
      public? true
    end

    attribute :replacement_host_key_id, :uuid do
      public? true
    end

    attribute :supersedes_host_key_id, :uuid do
      public? true
    end

    attribute :rotation_reason, :string do
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
    belongs_to :replacement_host_key, __MODULE__ do
      source_attribute :replacement_host_key_id
      public? true
      define_attribute? false
    end

    belongs_to :supersedes_host_key, __MODULE__ do
      source_attribute :supersedes_host_key_id
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_target_fingerprint, [
      :agent_id,
      :target_host,
      :target_port,
      :protocol,
      :fingerprint_sha256
    ]
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
