# In Postgrex 0.21+, Postgrex.Types.define/3 creates the module itself.
# Do not wrap this in a defmodule block.
Postgrex.Types.define(
  ServiceRadar.PostgresTypes,
  [AshPostgres.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
