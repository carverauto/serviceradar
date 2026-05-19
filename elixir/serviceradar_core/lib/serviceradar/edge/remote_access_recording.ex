defmodule ServiceRadar.Edge.RemoteAccessRecording do
  @moduledoc """
  Recording manifest for a generic remote-access session.

  This resource tracks policy, retention, storage location, and aggregate byte
  counts. Raw terminal input/output is not stored here.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @remote_access_ssh_permission "devices.remote_access.ssh.open"
  @remote_access_rdp_permission "devices.remote_access.rdp.open"
  @remote_access_ssh_check {ActorHasPermission, permission: @remote_access_ssh_permission}
  @remote_access_rdp_check {ActorHasPermission, permission: @remote_access_rdp_permission}

  @create_fields [
    :session_id,
    :policy,
    :storage_backend,
    :storage_bucket,
    :object_key,
    :manifest,
    :started_at,
    :retention_expires_at
  ]

  @finish_fields [
    :input_bytes,
    :output_bytes,
    :event_count,
    :manifest,
    :completed_at,
    :failure_reason
  ]

  postgres do
    table "remote_access_recordings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:manifest])
    decrypt_by_default([:manifest])
  end

  code_interface do
    define :create_recording, action: :create
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_session, action: :by_session, args: [:session_id]
    define :mark_active, action: :mark_active
    define :complete, action: :complete
    define :fail, action: :fail
    define :expire, action: :expire
    define :mark_deleted, action: :mark_deleted
    define :destroy_recording, action: :destroy
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
      get? true
      filter expr(session_id == ^arg(:session_id))
    end

    create :create do
      accept @create_fields
    end

    update :mark_active do
      accept [:started_at]
      change set_attribute(:status, :active)
    end

    update :complete do
      accept @finish_fields
      change set_attribute(:status, :completed)
    end

    update :fail do
      accept @finish_fields
      change set_attribute(:status, :failed)
    end

    update :expire do
      accept @finish_fields
      change set_attribute(:status, :expired)
    end

    update :mark_deleted do
      change set_attribute(:status, :deleted)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @remote_access_ssh_check
      authorize_if @remote_access_rdp_check
    end

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
      constraints one_of: [:pending, :active, :completed, :failed, :expired, :deleted]
      default :pending
    end

    attribute :policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :storage_backend, :string do
      allow_nil? false
      public? true
    end

    attribute :storage_bucket, :string do
      public? true
    end

    attribute :object_key, :string do
      allow_nil? false
      public? true
    end

    attribute :manifest, :map do
      allow_nil? false
      public? true
      default %{}
      sensitive? true
      description "Recording manifest encrypted at rest by AshCloak"
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

    attribute :input_bytes, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :output_bytes, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :event_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
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

  identities do
    identity :unique_session_id, [:session_id]
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
