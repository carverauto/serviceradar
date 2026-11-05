defmodule ServiceRadar.EventWriter.AlertAdmissionBacklogTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.AlertAdmissionBacklog
  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ScriptedStatefulAlertEngine

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  for signal <- [:event, :metric] do
    test "#{signal} records arriving behind a #{signal} backlog are admitted after it, in order" do
      signal = unquote(signal)
      ScriptedStatefulAlertEngine.use_in_test([{:error, {:overloaded, :rule_bytes}}])
      [first, second, third] = for n <- 1..3, do: record(signal, n)

      assert :ok = AlertAdmissionBacklog.admit(signal, [first, second])
      assert_receive {:evaluated, [_first, _second]}
      assert pending_ids(signal) == ids([first, second])

      # The lane holds a backlog, so the next record joins behind it instead
      # of being admitted ahead, and its batch admits the head in seq order.
      assert :ok = AlertAdmissionBacklog.admit(signal, [third])
      assert_receive {:evaluated, admitted}
      assert ids(admitted) == ids([first, second, third])
      refute_receive {:evaluated, _records}, 50
      assert pending_ids(signal) == []
    end
  end

  test "a genuine refusal fails the admission and defers nothing" do
    ScriptedStatefulAlertEngine.use_in_test([{:error, :alert_evaluation_draining}])
    event = record(:event, 1)

    assert {:error, :alert_evaluation_draining} = AlertAdmissionBacklog.admit(:event, [event])
    assert_receive {:evaluated, [_event]}
    assert pending_ids(:event) == []
  end

  test "the report publishes the backlog and is unhealthy once its head has waited too long" do
    ScriptedStatefulAlertEngine.use_in_test([{:error, :alert_evaluation_peer_not_ready}])
    parent = self()
    handler = "alert-admission-backlog-report-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:serviceradar, :event_writer, :alert_admission_backlog],
      fn _event, measurements, metadata, _config ->
        send(parent, {:backlog, metadata.lane, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = AlertAdmissionBacklog.report()
    assert_receive {:backlog, "event", %{pending_count: baseline}}
    assert {:ok, %{new_state: :healthy}} = current_health()

    assert :ok = AlertAdmissionBacklog.admit(:event, [record(:event, 1)])

    Repo.query!(
      "UPDATE platform.alert_pending_admissions SET inserted_at = now() - interval '11 minutes' " <>
        "WHERE lane = 'event'"
    )

    assert :ok = AlertAdmissionBacklog.report()
    assert_receive {:backlog, "event", %{pending_count: pending, oldest_pending_ms: oldest}}
    assert pending == baseline + 1
    assert oldest >= 600_000
    assert {:ok, %{new_state: :unhealthy}} = current_health()
  end

  defp record(:event, n) do
    %{
      id: Ash.UUID.generate(),
      time: DateTime.shift(~U[2026-11-05 12:00:00.000000Z], second: n),
      class_uid: 2004,
      severity_id: 4,
      message: "synthetic backlog event #{n}"
    }
  end

  defp record(:metric, n) do
    %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.shift(~U[2026-11-05 12:00:00.000000Z], second: n),
      gateway_id: "gateway-01",
      series_key: "synthetic:backlog:#{n}",
      metric_name: "synthetic_backlog_metric",
      value: n * 1.0
    }
  end

  defp ids(records), do: Enum.map(records, &to_string(&1.id))

  defp pending_ids(signal) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT occurrence->>'id'
        FROM platform.alert_pending_admissions
        WHERE lane = $1
        ORDER BY seq
        """,
        [Atom.to_string(signal)]
      )

    List.flatten(rows)
  end

  defp current_health, do: HealthTracker.current_status(:core, "alert-admission-backlog")
end
