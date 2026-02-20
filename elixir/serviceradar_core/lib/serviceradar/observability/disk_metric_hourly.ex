defmodule ServiceRadar.Observability.DiskMetricHourly do
  @moduledoc """
  Hourly disk metric rollups from `disk_metrics_hourly`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "disk_metrics_hourly"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  json_api do
    type "disk_metric_hourly"

    routes do
      base "/disk_metrics_hourly"
      index :read
    end
  end

  resource do
    require_primary_key? false
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    attribute :bucket, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :host_id, :string do
      public? true
    end

    attribute :mount_point, :string do
      public? true
    end

    attribute :avg_usage_percent, :float do
      public? true
    end

    attribute :max_usage_percent, :float do
      public? true
    end

    attribute :avg_used_bytes, :float do
      public? true
    end

    attribute :avg_available_bytes, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
