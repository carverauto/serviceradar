defmodule ServiceRadarWebNG.Repo do
  use AshPostgres.Repo,
    otp_app: :serviceradar_web_ng

  def installed_extensions do
    # Extensions available in the database
    ["uuid-ossp", "citext", "ash-functions"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end
end
