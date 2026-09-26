defmodule ServiceRadar.Monitoring.OcsfEvent do
  @moduledoc """
  OCSF Event Log Activity records stored in the `ocsf_events` hypertable.

  Read-only here. EventWriter (`ServiceRadar.EventWriter.Processors.Events`
  and the processors that emit events) is the only writer, after a JetStream
  hop. Core produces an event through
  `ServiceRadar.Events.OcsfEventPublisher`, which applies the out-of-service
  device suppression and runs the northbound event handlers.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Types.Jsonb

  postgres do
    table "ocsf_events"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
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

    attribute :metadata, Jsonb do
      default %{}
      public? true
    end

    attribute :observables, Jsonb do
      default []
      public? true
    end

    attribute :trace_id, :string do
      public? true
    end

    attribute :span_id, :string do
      public? true
    end

    attribute :actor, Jsonb do
      default %{}
      public? true
    end

    attribute :device, Jsonb do
      default %{}
      public? true
    end

    attribute :src_endpoint, Jsonb do
      default %{}
      public? true
    end

    attribute :dst_endpoint, Jsonb do
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

    attribute :unmapped, Jsonb do
      default %{}
      public? true
    end

    attribute :raw_data, :string do
      public? true
    end

    create_timestamp :created_at
  end
end
