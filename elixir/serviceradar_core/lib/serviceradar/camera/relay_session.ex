defmodule ServiceRadar.Camera.RelaySession do
  @moduledoc """
  Persistent control-plane relay session for a live camera view.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  import Ash.Expr

  alias ServiceRadar.Camera.RelayTermination
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}

  @create_fields [
    :camera_source_id,
    :stream_profile_id,
    :agent_id,
    :gateway_id,
    :lease_expires_at,
    :requested_by
  ]

  postgres do
    table "camera_relay_sessions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:requested]
    default_initial_state :requested
    state_attribute :status

    transitions do
      transition :mark_opening, from: :requested, to: :opening
      transition :activate, from: [:requested, :opening], to: :active
      transition :request_close, from: [:requested, :opening, :active], to: :closing
      transition :mark_closed, from: [:requested, :opening, :active, :closing], to: :closed
      transition :fail, from: [:requested, :opening, :active, :closing], to: :failed
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :create_session, action: :create
    define :mark_opening, action: :mark_opening
    define :activate, action: :activate
    define :renew_lease, action: :renew_lease
    define :request_close, action: :request_close
    define :mark_closed, action: :mark_closed
    define :fail_session, action: :fail
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:termination_kind])
    end

    create :create do
      accept @create_fields
    end

    update :mark_opening do
      accept [:command_id, :lease_token, :lease_expires_at]

      change transition_state(:opening)
      change set_attribute(:opened_at, &DateTime.utc_now/0)
    end

    update :activate do
      accept [:media_ingest_id, :lease_expires_at, :viewer_count]

      change transition_state(:active)
      change set_attribute(:activated_at, &DateTime.utc_now/0)
    end

    update :renew_lease do
      accept [:lease_expires_at, :viewer_count]
    end

    update :request_close do
      accept [:close_reason]

      change transition_state(:closing)
      change set_attribute(:close_requested_at, &DateTime.utc_now/0)
    end

    update :mark_closed do
      accept [:close_reason, :viewer_count]

      change transition_state(:closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:failure_reason, :close_reason, :viewer_count]

      change transition_state(:failed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@devices_view_check)

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :camera_source_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true

      constraints one_of: [:requested, :opening, :active, :closing, :closed, :failed]
      default :requested
    end

    attribute :command_id, :uuid do
      public? true
    end

    attribute :lease_token, :string do
      public? true
    end

    attribute :lease_expires_at, :utc_datetime_usec do
      public? true
    end

    attribute :media_ingest_id, :string do
      public? true
    end

    attribute :viewer_count, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :requested_by, :string do
      public? true
    end

    attribute :close_reason, :string do
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end

    attribute :opened_at, :utc_datetime_usec do
      public? true
    end

    attribute :activated_at, :utc_datetime_usec do
      public? true
    end

    attribute :close_requested_at, :utc_datetime_usec do
      public? true
    end

    attribute :closed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :camera_source, ServiceRadar.Camera.Source do
      allow_nil? false
      public? true
      source_attribute :camera_source_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :stream_profile, ServiceRadar.Camera.StreamProfile do
      allow_nil? false
      public? true
      source_attribute :stream_profile_id
      destination_attribute :id
      define_attribute? false
    end
  end

  calculations do
    calculate :termination_kind, :string, fn records, _opts ->
      Enum.map(records, &RelayTermination.kind_string/1)
    end
  end
end
