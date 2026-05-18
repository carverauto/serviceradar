defmodule ServiceRadar.Edge.RemoteAccessFileTransfer do
  @moduledoc """
  Metadata-only lifecycle record for remote-access file transfers.

  File contents are not stored here. Content-audit artifacts may be referenced
  only when explicit policy enables retention.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_permission "devices.remote_access.files.list"
  @view_check {ActorHasPermission, permission: @view_permission}

  @create_fields [
    :session_id,
    :requested_by,
    :device_uid,
    :target_kind,
    :target_host,
    :target_port,
    :agent_id,
    :gateway_id,
    :operation,
    :direction,
    :protocol,
    :credential_custody_mode,
    :target_path,
    :redacted_path,
    :path_hash,
    :destination_path,
    :destination_redacted_path,
    :destination_path_hash,
    :policy_snapshot,
    :policy_decision,
    :quota_snapshot,
    :approval_id,
    :retention_expires_at
  ]

  @finish_fields [
    :status,
    :byte_count,
    :file_count,
    :sha256,
    :policy_decision,
    :quota_snapshot,
    :content_audit_retained,
    :content_artifact_ref,
    :failure_reason,
    :completed_at
  ]

  postgres do
    table "remote_access_file_transfers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create_transfer, action: :create
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_session, action: :by_session, args: [:session_id]
    define :mark_started, action: :mark_started
    define :record_progress, action: :record_progress
    define :finish, action: :finish
    define :deny, action: :deny
    define :fail, action: :fail
    define :cancel, action: :cancel
    define :quota_exhausted, action: :quota_exhausted
    define :destroy_transfer, action: :destroy
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_session do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id))
    end

    create :create do
      accept @create_fields
    end

    update :mark_started do
      change set_attribute(:status, :started)
      change set_attribute(:started_at, &__MODULE__.utc_now/0)
    end

    update :record_progress do
      accept [:byte_count, :file_count, :quota_snapshot]
      change set_attribute(:status, :in_progress)
    end

    update :finish do
      accept @finish_fields
      change set_attribute(:status, :completed)
    end

    update :deny do
      accept @finish_fields
      change set_attribute(:status, :denied)
    end

    update :fail do
      accept @finish_fields
      change set_attribute(:status, :failed)
    end

    update :cancel do
      accept @finish_fields
      change set_attribute(:status, :canceled)
    end

    update :quota_exhausted do
      accept @finish_fields
      change set_attribute(:status, :quota_exhausted)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@view_check)

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:destroy) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :requested,
                    :started,
                    :in_progress,
                    :completed,
                    :denied,
                    :failed,
                    :canceled,
                    :quota_exhausted
                  ]

      default :requested
    end

    attribute :requested_by, :uuid do
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:inventory_device, :provider_console, :freeform_target]
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

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :operation, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :list,
                    :stat,
                    :download,
                    :upload,
                    :mkdir,
                    :rename,
                    :remove,
                    :chmod,
                    :chown
                  ]
    end

    attribute :direction, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:read, :write, :manage]
    end

    attribute :protocol, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:sftp]
      default :sftp
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

    attribute :target_path, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :redacted_path, :string do
      allow_nil? false
      public? true
    end

    attribute :path_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :destination_path, :string do
      public? false
      sensitive? true
    end

    attribute :destination_redacted_path, :string do
      public? true
    end

    attribute :destination_path_hash, :string do
      public? true
    end

    attribute :byte_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :file_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :sha256, :string do
      public? true
    end

    attribute :policy_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :policy_decision, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :quota_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :approval_id, :uuid do
      public? true
    end

    attribute :content_audit_retained, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :content_artifact_ref, :map do
      public? true
    end

    attribute :started_at, :utc_datetime do
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :retention_expires_at, :utc_datetime do
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :session, ServiceRadar.Edge.RemoteAccessSession do
      source_attribute :session_id
      allow_nil? false
      public? true
      define_attribute? false
    end
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
