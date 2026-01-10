defmodule ServiceRadar.Monitoring.OcsfEvent do
  @moduledoc """
  OCSF Event Log Activity records stored in the `ocsf_events` hypertable.

  This resource exposes read access for the Events UI and allows internal
  system writers (health, audit, syslog) to record OCSF events.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ocsf_events"
    repo ServiceRadar.Repo
    migrate? false
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    create :record do
      description "Record a new OCSF Event Log Activity entry"

      accept [
        :time,
        :class_uid,
        :category_uid,
        :type_uid,
        :activity_id,
        :activity_name,
        :severity_id,
        :severity,
        :message,
        :status_id,
        :status,
        :status_code,
        :status_detail,
        :metadata,
        :observables,
        :trace_id,
        :span_id,
        :actor,
        :device,
        :src_endpoint,
        :dst_endpoint,
        :log_name,
        :log_provider,
        :log_level,
        :log_version,
        :unmapped,
        :raw_data,
        :tenant_id
      ]

      change fn changeset, _context ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :time)) do
          Ash.Changeset.change_attribute(changeset, :time, DateTime.utc_now())
        else
          changeset
        end
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) in [:viewer, :operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    policy action(:record) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      default &Ash.UUID.generate/0
      public? true
    end

    attribute :time, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :class_uid, :integer do
      allow_nil? false
      public? true
    end

    attribute :category_uid, :integer do
      allow_nil? false
      public? true
    end

    attribute :type_uid, :integer do
      allow_nil? false
      public? true
    end

    attribute :activity_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :activity_name, :string do
      public? true
    end

    attribute :severity_id, :integer do
      public? true
    end

    attribute :severity, :string do
      public? true
    end

    attribute :message, :string do
      public? true
    end

    attribute :status_id, :integer do
      public? true
    end

    attribute :status, :string do
      public? true
    end

    attribute :status_code, :string do
      public? true
    end

    attribute :status_detail, :string do
      public? true
    end

    attribute :metadata, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :observables, ServiceRadar.Types.Jsonb do
      default []
      public? true
    end

    attribute :trace_id, :string do
      public? true
    end

    attribute :span_id, :string do
      public? true
    end

    attribute :actor, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :device, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :src_endpoint, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :dst_endpoint, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :log_name, :string do
      public? true
    end

    attribute :log_provider, :string do
      public? true
    end

    attribute :log_level, :string do
      public? true
    end

    attribute :log_version, :string do
      public? true
    end

    attribute :unmapped, ServiceRadar.Types.Jsonb do
      default %{}
      public? true
    end

    attribute :raw_data, :string do
      public? true
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end

    create_timestamp :created_at
  end
end
