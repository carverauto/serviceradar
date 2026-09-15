defmodule ServiceRadar.AnalyticsRepo do
  @moduledoc """
  Query pool for the pg_duckdb analytics head.

  Started only when the analytics-store head is configured. Writes still go
  through `ServiceRadar.AnalyticsStore` / EventWriter; this repo is SELECT
  only (SRQL and background jobs).
  """

  use Ecto.Repo,
    otp_app: :serviceradar_core,
    adapter: Ecto.Adapters.Postgres
end
