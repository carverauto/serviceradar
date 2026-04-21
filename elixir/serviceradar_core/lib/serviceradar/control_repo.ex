defmodule ServiceRadar.ControlRepo do
  @moduledoc """
  Protected database pool for control-plane critical paths.

  `ServiceRadar.Repo` remains the canonical Ash repo and general-purpose pool.
  This repo is intentionally separate so command/status persistence, heartbeats,
  and other foreground workflows can reserve database capacity even when Oban or
  maintenance work saturates the general pool.
  """

  use Ecto.Repo,
    otp_app: :serviceradar_core,
    adapter: Ecto.Adapters.Postgres
end
