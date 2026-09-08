defmodule ServiceRadar.Observability.TrivyReport do
  @moduledoc """
  Read model for Trivy report envelopes ingested from the Trivy sidecar.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trivy_reports"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :by_event_uuid do
      argument :event_uuid, :uuid, allow_nil?: false
      get? true
      filter expr(event_uuid == ^arg(:event_uuid))
    end

    read :recent do
      pagination offset?: true, default_limit: 50, max_page_size: 500
      prepare build(sort: [observed_at: :desc])
    end
  end

  attributes do
    attribute :event_uuid, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :log_uuid, :uuid, public?: true
    attribute :report_kind, :string, allow_nil?: false, public?: true
    attribute :cluster_id, :string, public?: true
    attribute :namespace, :string, public?: true
    attribute :name, :string, public?: true
    attribute :uid, :string, public?: true
    attribute :resource_version, :string, public?: true
    attribute :resource_kind, :string, public?: true
    attribute :resource_name, :string, public?: true
    attribute :resource_namespace, :string, public?: true
    attribute :pod_name, :string, public?: true
    attribute :pod_namespace, :string, public?: true
    attribute :pod_uid, :string, public?: true
    attribute :pod_ip, :string, public?: true
    attribute :host_ip, :string, public?: true
    attribute :node_name, :string, public?: true
    attribute :container_name, :string, public?: true
    attribute :owner_kind, :string, public?: true
    attribute :owner_name, :string, public?: true
    attribute :owner_uid, :string, public?: true
    attribute :severity_id, :integer, allow_nil?: false, public?: true
    attribute :severity_text, :string, public?: true
    attribute :status_id, :integer, allow_nil?: false, public?: true
    attribute :findings_count, :integer, allow_nil?: false, public?: true
    attribute :summary, :map, allow_nil?: false, public?: true
    attribute :owner_ref, :map, allow_nil?: false, public?: true
    attribute :correlation, :map, allow_nil?: false, public?: true
    attribute :report_metadata, :map, allow_nil?: false, public?: true
    attribute :report_payload, :map, allow_nil?: false, public?: true
    attribute :raw_payload, :map, allow_nil?: false, public?: true
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :findings, ServiceRadar.Observability.TrivyFinding do
      public? true
      destination_attribute :event_uuid
      source_attribute :event_uuid
    end
  end
end
