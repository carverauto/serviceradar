defmodule ServiceRadar.Repo do
  @moduledoc """
  ServiceRadar Core database repository.

  Uses AshPostgres for Ash resource persistence. The database connection
  is configured via the :serviceradar_core application config.

  ## Inherited Ecto.Repo Functions

  This module inherits all standard Ecto.Repo functions via AshPostgres.Repo,
  including `transact/2` and `all_by/3` from Ecto 3.12+.
  """
  use AshPostgres.Repo,
    otp_app: :serviceradar_core

  def installed_extensions do
    # Extensions available in the database
    ["uuid-ossp", "citext", "ash-functions"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end
end
