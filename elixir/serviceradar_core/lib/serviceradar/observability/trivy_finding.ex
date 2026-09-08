defmodule ServiceRadar.Observability.TrivyFinding do
  @moduledoc """
  Read model for actionable findings extracted from Trivy reports.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trivy_findings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :by_report do
      argument :event_uuid, :uuid, allow_nil?: false
      filter expr(event_uuid == ^arg(:event_uuid))
      pagination offset?: true, default_limit: 100, max_page_size: 1_000
      prepare build(sort: [severity_id: :desc, observed_at: :desc, finding_id: :asc])
    end

    read :recent do
      pagination offset?: true, default_limit: 100, max_page_size: 1_000
      prepare build(sort: [severity_id: :desc, observed_at: :desc, finding_id: :asc])
    end
  end

  attributes do
    attribute :finding_uuid, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :event_uuid, :uuid do
      allow_nil? false
      public? true
    end

    attribute :log_uuid, :uuid, public?: true

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :report_kind, :string, allow_nil?: false, public?: true
    attribute :cluster_id, :string, public?: true
    attribute :namespace, :string, public?: true
    attribute :agent_id, :string, public?: true
    attribute :device_uid, :string, public?: true
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
    attribute :image_repository, :string, public?: true
    attribute :image_tag, :string, public?: true
    attribute :image_digest, :string, public?: true
    attribute :finding_type, :string, allow_nil?: false, public?: true
    attribute :finding_id, :string, public?: true
    attribute :target, :string, public?: true
    attribute :title, :string, public?: true
    attribute :severity_text, :string, public?: true
    attribute :severity_id, :integer, allow_nil?: false, public?: true
    attribute :status, :string, public?: true
    attribute :package_name, :string, public?: true
    attribute :package_purl, :string, public?: true
    attribute :installed_version, :string, public?: true
    attribute :fixed_version, :string, public?: true
    attribute :description, :string, public?: true
    attribute :references, {:array, :string}, allow_nil?: false, public?: true
    attribute :raw_finding, :map, allow_nil?: false, public?: true
    attribute :fingerprint, :string, allow_nil?: false, public?: true
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :report, ServiceRadar.Observability.TrivyReport do
      public? true
      destination_attribute :event_uuid
      source_attribute :event_uuid
      define_attribute? false
    end
  end
end
