defmodule ServiceRadar.Observability.OtelServiceCatalogEntry do
  @moduledoc """
  One OTel service (`service.name`) that has reported logs, traces or metrics.

  Maps `platform.otel_service_catalog`: control-plane inventory that stays in
  CNPG whether or not StarRocks is the telemetry store. It holds no counts or
  samples, only the last time each signal was seen, so the service picker can
  search services without a DISTINCT over telemetry.

  Rows are written by `ServiceRadar.EventWriter.ServiceCatalog` (a throttled
  upsert after each persisted logs, traces or metrics batch), seeded once by
  `ServiceRadar.Observability.OtelServiceCatalogBackfillWorker`, and aged out by
  `ServiceRadar.Observability.OtelServiceCatalogPruneWorker`. SRQL reads it as
  `in:otel_services`.

  `last_seen_at` is the greatest of the three per-signal columns. It exists for
  pruning and the unscoped recency index only; readers derive recency from the
  per-signal columns they are allowed to see.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "otel_service_catalog"
    repo ServiceRadar.Repo
    schema "platform"
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
    attribute :service_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints max_length: 255
      description "OTel service.name, 1..255 characters"
    end

    attribute :logs_last_seen_at, :utc_datetime_usec do
      public? true
    end

    attribute :traces_last_seen_at, :utc_datetime_usec do
      public? true
    end

    attribute :metrics_last_seen_at, :utc_datetime_usec do
      public? true
      description "Covers both otel_metrics and otel_metric_points"
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Greatest of the per-signal columns; used for pruning only"
    end
  end
end
