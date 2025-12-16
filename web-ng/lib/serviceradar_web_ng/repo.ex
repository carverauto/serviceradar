defmodule ServiceRadarWebNG.Repo do
  use Ecto.Repo,
    otp_app: :serviceradar_web_ng,
    adapter: Ecto.Adapters.Postgres
end
