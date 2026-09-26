defmodule ServiceRadar.Observability.MtrHopAttributionBackfillDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Observability.MtrHopAttributionBackfill
  alias ServiceRadar.Repo

  @schema "platform"

  # Insert a trace row directly. time defaults to now() so it lands in the current chunk.
  defp insert_trace(attrs) do
    id = Ecto.UUID.generate()
    time = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO #{@schema}.mtr_traces
        (id, time, agent_id, target, target_ip, target_reached, device_id)
      VALUES ($1, $2, $3, $4, $5, false, $6)
      ON CONFLICT DO NOTHING
      """,
      [id, time, "agent-backfill-test", "test-host", attrs[:target_ip], attrs[:device_id]]
    )

    %{id: id, time: time, target_ip: attrs[:target_ip], device_id: attrs[:device_id]}
  end

  # Insert a hop row with target_ip = NULL (pre-backfill state).
  defp insert_hop(trace_id, time) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO #{@schema}.mtr_hops
        (id, time, trace_id, hop_number, sent, received, loss_pct)
      VALUES ($1, $2, $3, 1, 10, 10, 0.0)
      ON CONFLICT DO NOTHING
      """,
      [id, time, trace_id]
    )

    id
  end

  # Insert a hop with an unknown trace_id (simulates a trace that aged out).
  defp insert_orphan_hop do
    id = Ecto.UUID.generate()
    ghost_trace_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO #{@schema}.mtr_hops
        (id, time, trace_id, hop_number, sent, received, loss_pct)
      VALUES ($1, now(), $2, 1, 10, 10, 0.0)
      ON CONFLICT DO NOTHING
      """,
      [id, ghost_trace_id]
    )

    id
  end

  defp hop_attribution(hop_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT target_ip, device_id FROM #{@schema}.mtr_hops WHERE id = $1",
        [hop_id]
      )

    case rows do
      [[target_ip, device_id]] -> %{target_ip: target_ip, device_id: device_id}
      [] -> nil
    end
  end

  test "attributes target_ip and device_id from the owning trace" do
    trace = insert_trace(target_ip: "198.51.100.10", device_id: "sr:device-a")
    hop_id = insert_hop(trace.id, trace.time)

    assert {:ok, report} = MtrHopAttributionBackfill.run(mode: :execute)

    assert report.mode == :execute
    assert report.rows_updated >= 1

    attribution = hop_attribution(hop_id)
    assert attribution.target_ip == "198.51.100.10"
    assert attribution.device_id == "sr:device-a"
  end

  test "idempotent on a second full run" do
    trace = insert_trace(target_ip: "198.51.100.11", device_id: "sr:device-b")
    _hop_id = insert_hop(trace.id, trace.time)

    assert {:ok, _first} = MtrHopAttributionBackfill.run(mode: :execute)
    assert {:ok, second} = MtrHopAttributionBackfill.run(mode: :execute)

    assert second.rows_updated == 0,
           "second run should update nothing: rows were already attributed"
  end

  test "skips already-attributed rows, processing only remaining ones" do
    trace1 = insert_trace(target_ip: "198.51.100.20", device_id: "sr:device-c")
    trace2 = insert_trace(target_ip: "198.51.100.21", device_id: "sr:device-d")
    hop1_id = insert_hop(trace1.id, trace1.time)
    hop2_id = insert_hop(trace2.id, trace2.time)

    # Simulate a partial prior run: manually attribute hop1 (as if it was already processed).
    Repo.query!(
      "UPDATE #{@schema}.mtr_hops SET target_ip = $1, device_id = $2 WHERE id = $3",
      [trace1.target_ip, trace1.device_id, hop1_id]
    )

    assert {:ok, report} = MtrHopAttributionBackfill.run(mode: :execute)

    # Only hop2 should have been updated by the backfill.
    assert report.rows_updated == 1

    hop2_attr = hop_attribution(hop2_id)
    assert hop2_attr.target_ip == "198.51.100.21"
    assert hop2_attr.device_id == "sr:device-d"

    # hop1 retains its manually-set attribution and was not reprocessed.
    hop1_attr = hop_attribution(hop1_id)
    assert hop1_attr.target_ip == "198.51.100.20"
    assert hop1_attr.device_id == "sr:device-c"
  end

  test "hop whose trace carries no device_id is attributed with target_ip but not device_id" do
    trace = insert_trace(target_ip: "198.51.100.30", device_id: nil)
    hop_id = insert_hop(trace.id, trace.time)

    assert {:ok, _report} = MtrHopAttributionBackfill.run(mode: :execute)

    attribution = hop_attribution(hop_id)
    # target_ip is set (work marker cleared, so this hop won't be retried).
    assert attribution.target_ip == "198.51.100.30"
    # device_id stays NULL because the trace had none.
    assert is_nil(attribution.device_id)
  end

  test "orphan hop with no matching trace is counted as unrecoverable, not pending" do
    hop_id = insert_orphan_hop()

    assert {:ok, report} = MtrHopAttributionBackfill.run(mode: :execute)

    assert report.rows_unrecoverable >= 1,
           "orphan hop should appear in rows_unrecoverable"

    # The orphan hop still has NULL target_ip and cannot be attributed.
    assert is_nil(hop_attribution(hop_id).target_ip)
  end
end
