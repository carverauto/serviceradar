defmodule ServiceRadar.Inventory.SourceIdentityConflict do
  @moduledoc """
  Persisted diagnostics for source-authoritative identity drift.

  These records are intentionally not retention-managed like operational
  telemetry. They remain visible until a repair resolves them or an operator
  explicitly dismisses them.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @create_fields [
    :source_type,
    :source_id,
    :source_identifier_type,
    :source_identifier_value,
    :device_uid,
    :current_ip,
    :current_mac,
    :site,
    :conflict_category,
    :conflicting_identifiers,
    :proposed_action,
    :confidence,
    :status,
    :first_detected_at,
    :last_detected_at,
    :resolved_at,
    :dismissed_at,
    :repair_audit,
    :metadata
  ]

  postgres do
    table "source_identity_conflicts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_open, action: :open
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :open do
      filter expr(status == "open")
      prepare build(sort: [last_detected_at: :desc])
    end

    create :record do
      accept @create_fields
    end

    update :resolve do
      accept [:status, :resolved_at, :repair_audit, :metadata]
      change set_attribute(:status, "resolved")
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
    end

    update :dismiss do
      accept [:status, :dismissed_at, :metadata]
      change set_attribute(:status, "dismissed")
      change set_attribute(:dismissed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
  end

  attributes do
    uuid_primary_key :id

    attribute :source_type, :string do
      allow_nil? false
      public? true
    end

    attribute :source_id, :string do
      public? true
    end

    attribute :source_identifier_type, :string do
      public? true
    end

    attribute :source_identifier_value, :string do
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :current_ip, :string do
      public? true
    end

    attribute :current_mac, :string do
      public? true
    end

    attribute :site, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :conflict_category, :string do
      allow_nil? false
      public? true
    end

    attribute :conflicting_identifiers, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :proposed_action, :string do
      public? true
    end

    attribute :confidence, :string do
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "open"
      public? true
    end

    attribute :first_detected_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_detected_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
      public? true
    end

    attribute :dismissed_at, :utc_datetime_usec do
      public? true
    end

    attribute :repair_audit, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end
end
