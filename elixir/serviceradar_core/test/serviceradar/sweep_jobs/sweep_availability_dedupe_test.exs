defmodule ServiceRadar.SweepJobs.SweepAvailabilityDedupeTest do
  use ExUnit.Case, async: true

  # Exercises the private dedupe via the module under test.
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  defp record(device_uid, agent_id, checked_at, available?) do
    %{
      device_uid: device_uid,
      agent_id: agent_id,
      checked_at: checked_at,
      is_available: available?
    }
  end

  test "keeps only the freshest row per (device_uid, agent_id)" do
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    newer = DateTime.utc_now()

    deduped =
      SweepResultsIngestor.dedupe_availability_records([
        record("dev-1", "agent-a", older, false),
        record("dev-1", "agent-a", newer, true),
        record("dev-2", "agent-a", older, true)
      ])

    assert length(deduped) == 2

    dev1 = Enum.find(deduped, &(&1.device_uid == "dev-1"))
    assert dev1.checked_at == newer
    assert dev1.is_available
  end

  test "passes distinct keys through untouched" do
    now = DateTime.utc_now()

    rows = [
      record("dev-1", "agent-a", now, true),
      record("dev-1", "agent-b", now, true)
    ]

    assert rows |> SweepResultsIngestor.dedupe_availability_records() |> length() == 2
  end
end
