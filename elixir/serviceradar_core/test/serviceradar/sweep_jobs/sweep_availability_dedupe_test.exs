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
    older = DateTime.shift(DateTime.utc_now(), minute: -1)
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

  test "a device swept at two addresses is up when either answered, in any order" do
    now = DateTime.utc_now()
    later = DateTime.shift(now, second: 1)
    answered = record("dev-1", "agent-a", now, true)
    failed = record("dev-1", "agent-a", later, false)

    for rows <- [[answered, failed], [failed, answered]] do
      assert [%{is_available: true, checked_at: ^now}] =
               SweepResultsIngestor.dedupe_availability_records(rows)
    end
  end

  test "passes distinct keys through untouched" do
    now = DateTime.utc_now()

    rows = [
      record("dev-1", "agent-a", now, true),
      record("dev-1", "agent-b", now, true)
    ]

    assert rows |> SweepResultsIngestor.dedupe_availability_records() |> length() == 2
  end

  test "returns rows in key order so concurrent upserts lock rows in the same order" do
    now = DateTime.utc_now()

    # More than 32 keys, where map iteration stops following key order.
    rows = for n <- 64..1//-1, do: record("dev-#{n}", "agent-a", now, true)

    keys =
      rows
      |> SweepResultsIngestor.dedupe_availability_records()
      |> Enum.map(&{&1.device_uid, &1.agent_id})

    assert keys == Enum.sort(keys)
    assert length(keys) == 64
  end

  # Host results share the contract: one row per conflict key, in key order, with an
  # answered result kept over one that did not answer.
  test "host result rows are one per (execution_id, ip), in key order, answered first" do
    rows =
      for n <- 64..1//-1, status <- [:available, :unavailable] do
        %{execution_id: "exec-a", ip: "192.0.2.#{n}", status: status}
      end

    deduped = SweepResultsIngestor.dedupe_host_results(rows)
    keys = Enum.map(deduped, &{&1.execution_id, &1.ip})

    assert keys == Enum.sort(keys)
    assert length(keys) == 64
    assert Enum.all?(deduped, &(&1.status == :available))
  end
end
