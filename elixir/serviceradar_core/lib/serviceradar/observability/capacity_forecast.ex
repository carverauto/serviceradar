defmodule ServiceRadar.Observability.CapacityForecast do
  @moduledoc """
  Capacity forecast snapshots for monitored resources.

  Rows are keyed by forecast generation time, resource series, metric, and
  horizon so a forecasting job can safely retry the same run while retaining
  historical forecast snapshots. The underlying TimescaleDB hypertable is
  managed by raw SQL migrations.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table("capacity_forecasts")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  json_api do
    type("capacity_forecast")

    primary_key do
      keys([:forecasted_at, :resource_key, :metric_name, :horizon_seconds])
    end

    routes do
      base("/capacity_forecasts")
      index(:read)
    end
  end

  actions do
    defaults([:destroy])

    read :read do
      primary?(true)

      pagination do
        offset?(true)
        default_limit(100)
        max_page_size(1000)
        required?(true)
      end
    end

    read :by_resource do
      argument(:resource_key, :string, allow_nil?: false)
      filter(expr(resource_key == ^arg(:resource_key)))
    end

    read :at_risk do
      filter(expr(status == "projected" and not is_nil(projected_exhaustion_at)))
    end

    create :upsert do
      accept([
        :forecasted_at,
        :resource_key,
        :resource_type,
        :resource_id,
        :resource_label,
        :metric_class,
        :metric_name,
        :horizon_seconds,
        :horizon_ends_at,
        :window_started_at,
        :window_ended_at,
        :sample_count,
        :model,
        :status,
        :skip_reason,
        :current_value,
        :slope_per_second,
        :intercept,
        :projected_value,
        :projected_exhaustion_at,
        :exhaustion_threshold,
        :confidence,
        :lower_bound,
        :upper_bound,
        :metadata
      ])

      upsert?(true)
      upsert_identity(:unique_capacity_forecast)

      upsert_fields([
        :resource_type,
        :resource_id,
        :resource_label,
        :metric_class,
        :horizon_ends_at,
        :window_started_at,
        :window_ended_at,
        :sample_count,
        :model,
        :status,
        :skip_reason,
        :current_value,
        :slope_per_second,
        :intercept,
        :projected_value,
        :projected_exhaustion_at,
        :exhaustion_threshold,
        :confidence,
        :lower_bound,
        :upper_bound,
        :metadata,
        :updated_at
      ])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()

    policy action([:upsert, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  attributes do
    attribute :forecasted_at, :utc_datetime_usec do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      description("When the forecast snapshot was generated")
    end

    attribute :resource_key, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      description("Stable series key for the forecasted resource")
    end

    attribute :metric_name, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      description("Forecasted metric name")
    end

    attribute :horizon_seconds, :integer do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      description("Forecast horizon in seconds")
    end

    attribute :resource_type, :string do
      allow_nil?(false)
      public?(true)
      description("Resource family, such as cpu, memory, disk, or interface")
    end

    attribute :resource_id, :string do
      allow_nil?(false)
      public?(true)
      description("Inventory identifier for the parent resource")
    end

    attribute :resource_label, :string do
      public?(true)
      description("Human readable resource label")
    end

    attribute :metric_class, :string do
      allow_nil?(false)
      public?(true)
      description("Forecast metric class used for config and routing")
    end

    attribute :horizon_ends_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      description("Forecast horizon endpoint")
    end

    attribute :window_started_at, :utc_datetime_usec do
      public?(true)
      description("Oldest aggregate sample used by the forecast")
    end

    attribute :window_ended_at, :utc_datetime_usec do
      public?(true)
      description("Newest aggregate sample used by the forecast")
    end

    attribute :sample_count, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
      description("Number of aggregate samples used")
    end

    attribute :model, :string do
      allow_nil?(false)
      default("linear")
      public?(true)
      description("Forecasting model identifier")
    end

    attribute :status, :string do
      allow_nil?(false)
      default("projected")
      public?(true)
      description("Forecast state, for example projected or skipped")
    end

    attribute :skip_reason, :string do
      public?(true)
      description("Reason a projection was skipped")
    end

    attribute :current_value, :float do
      public?(true)
      description("Latest observed aggregate value at forecast time")
    end

    attribute :slope_per_second, :float do
      public?(true)
      description("Projected value change per second")
    end

    attribute :intercept, :float do
      public?(true)
      description("Model intercept in metric units")
    end

    attribute :projected_value, :float do
      public?(true)
      description("Projected metric value at the horizon")
    end

    attribute :projected_exhaustion_at, :utc_datetime_usec do
      public?(true)
      description("Estimated time the resource crosses the exhaustion threshold")
    end

    attribute :exhaustion_threshold, :float do
      public?(true)
      description("Threshold used to compute projected exhaustion")
    end

    attribute :confidence, :float do
      public?(true)
      description("Forecast confidence from 0.0 to 1.0")
    end

    attribute :lower_bound, :float do
      public?(true)
      description("Lower confidence interval bound at the horizon")
    end

    attribute :upper_bound, :float do
      public?(true)
      description("Upper confidence interval bound at the horizon")
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
      description("Forecast metadata such as SRQL query and fit diagnostics")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_capacity_forecast, [
      :forecasted_at,
      :resource_key,
      :metric_name,
      :horizon_seconds
    ])
  end
end
