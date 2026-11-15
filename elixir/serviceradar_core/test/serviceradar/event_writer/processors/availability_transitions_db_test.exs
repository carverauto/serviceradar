defmodule ServiceRadar.EventWriter.Processors.AvailabilityTransitionsDBTest do
  @moduledoc """
  Without StarRocks the merged availability history is stored in the CNPG hypertable, once
  per record however often it is delivered.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.EventWriter.Processors.AvailabilityTransitions
  alias ServiceRadar.Repo

  @moduletag :integration

  @uid "sr:00000000-0000-4000-8000-0000000000a1"

  defp message(record), do: %{data: Jason.encode!(record), metadata: %{}}

  defp record(changed_at, from, to, from_since) do
    %{
      "device_uid" => @uid,
      "from_state" => from,
      "from_since" => from_since,
      "to_state" => to,
      "changed_at" => changed_at,
      "source_kind" => "camera",
      "conflict" => false
    }
  end

  test "a redelivered or republished record is stored once, and other changes alongside it" do
    down = record("2026-01-01T06:00:00Z", "available", "unavailable", "2026-01-01T00:00:00Z")
    up = record("2026-01-01T06:10:00Z", "unavailable", "available", "2026-01-01T06:00:00Z")

    assert {:ok, 1} =
             AvailabilityTransitions.process_batch([message(down)], starrocks_enabled: false)

    assert {:ok, 1} =
             AvailabilityTransitions.process_batch([message(down), message(up)],
               starrocks_enabled: false
             )

    %{rows: rows} =
      Repo.query!(
        """
        SELECT from_state, to_state, from_since, changed_at
        FROM platform.device_availability_transitions
        WHERE device_uid = $1 ORDER BY changed_at
        """,
        [@uid]
      )

    assert [
             ["available", "unavailable", from_since, ~U[2026-01-01 06:00:00.000000Z]],
             ["unavailable", "available", ~U[2026-01-01 06:00:00.000000Z], _up_at]
           ] = rows

    assert DateTime.compare(from_since, ~U[2026-01-01 00:00:00Z]) == :eq
  end
end
