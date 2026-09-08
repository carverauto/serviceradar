defmodule ServiceRadar.Edge.RemoteAccessRecordingEvent do
  @moduledoc """
  Policy-gated replay event for a remote-access recording.

  Events store transcript metadata by default. Terminal payload text is present
  only when trusted recording policy explicitly enables raw content capture.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  @create_fields [
    :recording_id,
    :session_id,
    :sequence,
    :stream,
    :event_type,
    :occurred_at,
    :byte_count,
    :payload_sha256,
    :prior_event_hash,
    :payload_text,
    :payload_redacted,
    :redaction_reason,
    :metadata,
    :retention_expires_at
  ]

  postgres do
    table "remote_access_recording_events"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:payload_text])
    decrypt_by_default([:payload_text])
  end

  code_interface do
    define :record, action: :record
    define :list_for_recording, action: :for_recording, args: [:recording_id]
    define :list_for_session, action: :for_session, args: [:session_id]

    define :latest_before_sequence,
      action: :latest_before_sequence,
      args: [:recording_id, :sequence]
  end

  actions do
    defaults [:read, :destroy]

    read :for_recording do
      argument :recording_id, :uuid, allow_nil?: false
      filter expr(recording_id == ^arg(:recording_id))
      prepare build(sort: [sequence: :asc, inserted_at: :asc])
    end

    read :for_session do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id))
      prepare build(sort: [sequence: :asc, inserted_at: :asc])
    end

    read :latest_before_sequence do
      argument :recording_id, :uuid, allow_nil?: false
      argument :sequence, :integer, allow_nil?: false
      filter expr(recording_id == ^arg(:recording_id) and sequence < ^arg(:sequence))
      prepare build(sort: [sequence: :desc, inserted_at: :desc], limit: 1)
    end

    create :record do
      accept @create_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type([:read, :create, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :recording_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :session_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :sequence, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :stream, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:input, :output, :resize, :event, :enhanced_event]
    end

    attribute :event_type, :string do
      allow_nil? false
      public? true
    end

    attribute :occurred_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :byte_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :payload_sha256, :string do
      public? true
    end

    attribute :prior_event_hash, :string do
      public? true
    end

    attribute :payload_text, :string do
      public? true
      sensitive? true
      description "Optional terminal payload text encrypted at rest by AshCloak"
    end

    attribute :payload_redacted, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :redaction_reason, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :retention_expires_at, :utc_datetime do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :recording, ServiceRadar.Edge.RemoteAccessRecording do
      source_attribute :recording_id
      allow_nil? false
      public? true
      define_attribute? false
    end

    belongs_to :session, ServiceRadar.Edge.RemoteAccessSession do
      source_attribute :session_id
      allow_nil? false
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_recording_sequence, [:recording_id, :sequence]
  end
end
