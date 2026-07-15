defmodule ServiceRadar.Automation.Callbacks.Use do
  @moduledoc """
  Replay-bounded idempotency and immutable response retention for a callback use.

  A committed row privately retains at most 256 KiB of sensitive response bytes
  so a lost first response can be replayed byte-for-byte exactly once per
  server-minted idempotency key. Public projections expose only its schema,
  size, policy version, and fingerprint.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Callbacks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "automation_callback_uses"
    repo ServiceRadar.Repo
    schema "platform"

    identity_wheres_to_sql unique_committed_budget_slot: "state = 'committed'"

    identity_index_names unique_idempotency_key: "automation_callback_uses_idempotency_uidx",
                         unique_committed_budget_slot:
                           "automation_callback_uses_committed_budget_uidx"

    references do
      reference :grant, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_by_idempotency_verifier,
      action: :by_idempotency_verifier,
      args: [:grant_id, :idempotency_key_verifier]

    define :list_for_grant, action: :for_grant, args: [:grant_id]
    define :reserve, action: :reserve
    define :commit_response, action: :commit_response
    define :abort, action: :abort
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_idempotency_verifier do
      argument :grant_id, :uuid, allow_nil?: false
      argument :idempotency_key_verifier, :binary, allow_nil?: false, sensitive?: true
      get? true

      filter expr(
               grant_id == ^arg(:grant_id) and
                 idempotency_key_verifier == ^arg(:idempotency_key_verifier)
             )
    end

    read :for_grant do
      argument :grant_id, :uuid, allow_nil?: false
      filter expr(grant_id == ^arg(:grant_id))
      prepare build(sort: [reserved_at: :asc])
    end

    create :reserve do
      primary? true

      accept [
        :grant_id,
        :idempotency_key_verifier,
        :idempotency_pepper_version,
        :request_fingerprint,
        :reserved_at
      ]
    end

    update :commit_response do
      require_atomic? true

      accept [
        :budget_sequence,
        :response_reference,
        :response_bytes,
        :response_fingerprint,
        :response_size_bytes,
        :response_schema_version,
        :policy_version,
        :committed_at
      ]

      filter expr(state == :reserved)
      change set_attribute(:state, :committed)
    end

    update :abort do
      require_atomic? true
      accept [:abort_reason, :aborted_at]
      filter expr(state == :reserved)
      change set_attribute(:state, :aborted)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_grant], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :grant_id, :uuid, allow_nil?: false, public?: true

    attribute :idempotency_key_verifier, :binary do
      allow_nil? false
      public? false
      sensitive? true
      description "Keyed verifier for the caller's idempotency key; never the plaintext key"
    end

    attribute :idempotency_pepper_version, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :request_fingerprint, :string, allow_nil?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      default :reserved
      public? true
      constraints one_of: [:reserved, :committed, :aborted]
    end

    attribute :budget_sequence, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 1_000
    end

    attribute :response_reference, :string do
      allow_nil? true
      public? false
      sensitive? true

      description "Optional immutable object reference for deployments that externalize retained response bytes"
    end

    attribute :response_bytes, :binary do
      allow_nil? true
      public? false
      sensitive? true

      description "Immutable bounded response bytes retained only for exact lost-response replay"
    end

    attribute :response_fingerprint, :string, allow_nil?: true, public?: true

    attribute :response_size_bytes, :integer do
      allow_nil? true
      public? true
      constraints min: 0, max: 262_144
    end

    attribute :response_schema_version, :string, allow_nil?: true, public?: true
    attribute :policy_version, :string, allow_nil?: true, public?: true
    attribute :abort_reason, :string, allow_nil?: true, public?: true
    attribute :reserved_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :committed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :aborted_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :grant, ServiceRadar.Automation.Callbacks.Grant do
      define_attribute? false
      source_attribute :grant_id
    end

    has_many :audit_events, ServiceRadar.Automation.Callbacks.AuditEvent do
      destination_attribute :use_id
    end
  end

  identities do
    identity :unique_idempotency_key, [:grant_id, :idempotency_key_verifier]

    identity :unique_committed_budget_slot, [:grant_id, :budget_sequence],
      where: expr(state == :committed)
  end
end
