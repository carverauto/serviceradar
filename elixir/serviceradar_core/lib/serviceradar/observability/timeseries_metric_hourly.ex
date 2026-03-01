defmodule ServiceRadar.Observability.TimeseriesMetricHourly do
  @moduledoc """
  Hourly timeseries metric rollups from `timeseries_metrics_hourly`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "timeseries_metrics_hourly"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  json_api do
    type "timeseries_metric_hourly"

    routes do
      base "/timeseries_metrics_hourly"
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

    attribute :metric_type, :string do
      public? true
    end

    attribute :metric_name, :string do
      public? true
    end

    attribute :avg_value, :float do
      public? true
    end

    attribute :min_value, :float do
      public? true
    end

    attribute :max_value, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
