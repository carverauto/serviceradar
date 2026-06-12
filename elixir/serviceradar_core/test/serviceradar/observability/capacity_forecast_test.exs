defmodule ServiceRadar.Observability.CapacityForecastTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.CapacityForecast

  @migration_path "priv/repo/migrations/20260612080000_create_capacity_forecasts.exs"

  test "resource is raw-managed in the platform schema" do
    assert PostgresInfo.table(CapacityForecast) == "capacity_forecasts"
    assert PostgresInfo.schema(CapacityForecast) == "platform"
    refute PostgresInfo.migrate?(CapacityForecast)

    assert CapacityForecast in Ash.Domain.Info.resources(Observability)
  end

  test "resource exposes the forecast snapshot fields required by capacity planning" do
    attributes = CapacityForecast |> Info.attributes() |> Map.new(&{&1.name, &1})

    for field <- [
          :forecasted_at,
          :resource_key,
          :resource_type,
          :resource_id,
          :metric_class,
          :metric_name,
          :horizon_seconds,
          :horizon_ends_at,
          :slope_per_second,
          :projected_value,
          :projected_exhaustion_at,
          :confidence,
          :lower_bound,
          :upper_bound
        ] do
      assert Map.has_key?(attributes, field)
    end

    assert attributes.forecasted_at.primary_key?
    assert attributes.resource_key.primary_key?
    assert attributes.metric_name.primary_key?
    assert attributes.horizon_seconds.primary_key?
  end

  test "upsert action is keyed for idempotent forecast cron retries" do
    action = Info.action(CapacityForecast, :upsert)
    identity = Info.identity(CapacityForecast, :unique_capacity_forecast)

    assert action.upsert?
    assert action.upsert_identity == :unique_capacity_forecast

    assert identity.keys == [
             :forecasted_at,
             :resource_key,
             :metric_name,
             :horizon_seconds
           ]

    assert :projected_value in action.upsert_fields
    assert :projected_exhaustion_at in action.upsert_fields
    assert :confidence in action.upsert_fields
  end

  test "raw migration creates a platform hypertable with forecast confidence fields" do
    migration = File.read!(@migration_path)

    assert migration =~ "CREATE TABLE IF NOT EXISTS \#{schema()}.capacity_forecasts"
    assert migration =~ "PRIMARY KEY (forecasted_at, resource_key, metric_name, horizon_seconds)"
    assert migration =~ "create_hypertable"
    assert migration =~ "'forecasted_at'"
    assert migration =~ "projected_exhaustion_at"
    assert migration =~ "confidence"
    assert migration =~ "lower_bound"
    assert migration =~ "upper_bound"
    refute migration =~ "public.capacity_forecasts"
  end
end
