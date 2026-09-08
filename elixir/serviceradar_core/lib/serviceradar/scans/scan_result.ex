defmodule ServiceRadar.Scans.ScanResult do
  @moduledoc """
  Per-target/per-port result of an ad-hoc ICMP/TCP scan.

  Maps to the `adhoc_scan_results` TimescaleDB hypertable, whose schema is
  managed by a raw SQL migration (`migrate? false`). Rows are written by the
  event-writer pipeline after results traverse JetStream — never by a direct
  agent/gateway DB write. MTR results for the same run live in `mtr_traces`
  and are joined on `scan_run_id`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Scans,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "adhoc_scan_results"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  resource do
    require_primary_key? false
  end

  code_interface do
    define :by_scan_run, action: :by_scan_run, args: [:scan_run_id]
    define :create, action: :create
  end

  actions do
    defaults [:read]

    read :by_scan_run do
      argument :scan_run_id, :uuid, allow_nil?: false
      filter expr(scan_run_id == ^arg(:scan_run_id))
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
    end

    read :recent do
      description "Results from the last 24 hours"
      filter expr(time > ago(24, :hour))
    end

    create :create do
      accept [
        :id,
        :time,
        :scan_run_id,
        :agent_id,
        :gateway_id,
        :partition,
        :target_ip,
        :mode,
        :port,
        :available,
        :response_ms,
        :service
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  attributes do
    attribute :id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :time, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the probe completed"
    end

    attribute :scan_run_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :target_ip, :string do
      allow_nil? false
      public? true
    end

    attribute :mode, :string do
      allow_nil? false
      public? true
      description "icmp or tcp"
    end

    attribute :port, :integer do
      public? true
      description "TCP port (nil for icmp)"
    end

    attribute :available, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :response_ms, :float do
      public? true
      description "Round-trip time in milliseconds"
    end

    attribute :service, :string do
      public? true
      description "Detected service/banner for an open TCP port"
    end
  end
end
