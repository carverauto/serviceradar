defmodule ServiceRadar.Repo.Migrations.RepairAnomalyEpisodeLastPayload do
  @moduledoc """
  Re-parses `anomaly_episodes.last_payload` values stored as JSONB string
  scalars back into JSONB objects.

  The episode registry's upsert bound `Jason.encode!(payload)` to a
  `$n::jsonb` placeholder; Postgrex's jsonb encoder serialized that binary
  again, so every row written before the fix carries the payload as a
  double-encoded JSONB string. Ash cannot load a string into the `:map`
  typed `last_payload` field, which crashed every AnomalyEpisode read
  (device-page anomaly panels).

  Idempotent: after repair `jsonb_typeof` is `object` and the predicate no
  longer matches. Forward-only — the string form was never a valid state.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{schema()}.anomaly_episodes
    SET last_payload = (last_payload #>> '{}')::jsonb
    WHERE jsonb_typeof(last_payload) = 'string'
    """)
  end

  def down do
    :ok
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
