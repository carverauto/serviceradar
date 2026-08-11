defmodule ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycleNotificationTest do
  @moduledoc """
  The loop this branch exists to close: an incident that fires produces a
  routing request, and an incident that resolves produces a second one.

  Both need the database - `create_event_and_alert/4` records an OCSF event,
  generates the alert, and writes rule history before anything is enqueued, and
  the assertion is on rows in `platform.oban_jobs`. This is deliberately the
  only database-backed test of the wiring; the reason-by-reason contract and the
  change's hook are asserted without one in
  `ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycleRoutingTest` and
  `ServiceRadar.Monitoring.Changes.EnqueueRoutingRequestTest`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @routing_worker "ServiceRadar.Notifications.RoutingWorker"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:alert_lifecycle_notification_test)}
  end

  test "firing an incident enqueues exactly one :fire routing request", %{actor: actor} do
    now = DateTime.utc_now()
    rule = create_rule!(actor)

    assert {:ok, alert_id} =
             AlertLifecycle.create_event_and_alert(rule, snapshot(rule), record(now), now)

    assert [job] = routing_jobs(alert_id)
    assert job["worker"] == @routing_worker
    assert job["queue"] == "notifications"
    assert job["args"]["lifecycle_reason"] == "fire"
    assert job["args"]["alert_id"] == alert_id

    # `step_number` and `dedupe_key` are present and null rather than absent:
    # the worker's `unique` digest is computed over those keys, and a key that
    # is sometimes missing hashes differently from the same key set to nil.
    assert Map.has_key?(job["args"], "step_number")
    assert Map.has_key?(job["args"], "dedupe_key")
  end

  test "resolving that incident enqueues one :resolve routing request", %{actor: actor} do
    now = DateTime.utc_now()
    rule = create_rule!(actor)

    assert {:ok, alert_id} =
             AlertLifecycle.create_event_and_alert(rule, snapshot(rule), record(now), now)

    resolved_at = DateTime.add(now, 60, :second)

    assert :ok = AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), resolved_at)

    assert [fire, resolve] = routing_jobs(alert_id)
    assert fire["args"]["lifecycle_reason"] == "fire"
    assert resolve["args"]["lifecycle_reason"] == "resolve"
    assert resolve["worker"] == @routing_worker
    assert resolve["queue"] == "notifications"
  end

  test "an alert that was already resolved out of band enqueues nothing", %{actor: actor} do
    # `resolve_alert/4` is idempotent by design - a duplicate clear, a REST
    # resolve, or a retry finds a terminal alert and no-ops. It must not emit a
    # resolution notification on that path either, or every retry pages again.
    now = DateTime.utc_now()
    rule = create_rule!(actor)

    assert {:ok, alert_id} =
             AlertLifecycle.create_event_and_alert(rule, snapshot(rule), record(now), now)

    assert :ok = AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), now)
    before = length(routing_jobs(alert_id))

    assert :ok = AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), now)
    assert length(routing_jobs(alert_id)) == before
  end

  test "a failed :resolve enqueue rolls back the alert transition", %{actor: actor} do
    now = DateTime.utc_now()
    rule = create_rule!(actor)

    assert {:ok, alert_id} =
             AlertLifecycle.create_event_and_alert(rule, snapshot(rule), record(now), now)

    assert {:error, {:routing_enqueue_failed, :queue_down}} =
             AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), now,
               enqueue_routing: fn ^alert_id, :resolve -> {:error, :queue_down} end
             )

    assert {:ok, alert} = Alert.get_by_id(alert_id, actor: actor)
    assert alert.status == :pending

    assert [fire] = routing_jobs(alert_id)
    assert fire["args"]["lifecycle_reason"] == "fire"
  end

  test "an alert read failure is not mistaken for an already-deleted incident" do
    now = DateTime.utc_now()
    rule = %{id: Ash.UUID.generate(), name: "read-failure"}
    alert_id = Ash.UUID.generate()

    assert {:error, {:alert_load_failed, :database_unavailable}} =
             AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), now,
               load_alert: fn ^alert_id, _opts -> {:error, :database_unavailable} end
             )
  end

  test "a mixed read error is not swallowed merely because it contains not-found" do
    now = DateTime.utc_now()
    rule = %{id: Ash.UUID.generate(), name: "mixed-read-failure"}
    alert_id = Ash.UUID.generate()
    reason = %{errors: [%Ash.Error.Query.NotFound{}, :database_unavailable]}

    assert {:error, {:alert_load_failed, ^reason}} =
             AlertLifecycle.resolve_alert(alert_id, rule, snapshot(rule), now,
               load_alert: fn ^alert_id, _opts -> {:error, reason} end
             )
  end

  test "a synthetic liveness probe is recorded but never routed", %{actor: actor} do
    now = DateTime.utc_now()
    rule = create_rule!(actor)

    assert {:ok, alert_id} =
             AlertLifecycle.create_event_and_alert(
               rule,
               synthetic_snapshot(rule),
               synthetic_record(now),
               now
             )

    assert routing_jobs(alert_id) == []

    assert :ok =
             AlertLifecycle.resolve_alert(alert_id, rule, synthetic_snapshot(rule), now)

    assert {:ok, alert} = Alert.get_by_id(alert_id, actor: actor)
    assert alert.status == :resolved
    assert routing_jobs(alert_id) == []
  end

  defp create_rule!(actor) do
    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "notification-wiring-#{System.unique_integer([:positive])}",
          enabled: true,
          signal: :event,
          match: %{"always" => true},
          group_by: ["serviceradar.sync.integration_source_id"],
          threshold: 1,
          window_seconds: 120,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600
        },
        actor: actor
      )
      |> Ash.create()

    rule
  end

  defp snapshot(rule) do
    %{
      rule_id: rule.id,
      group_key: "notification-wiring",
      group_values: %{"source" => "test"},
      window_count: 1,
      bucket_counts: %{},
      current_bucket_start: nil,
      last_seen_at: nil,
      last_fired_at: nil,
      last_notification_at: nil,
      cooldown_until: nil,
      alert_id: nil,
      first_seen_at: nil,
      diagnostics: %{}
    }
  end

  defp record(now) do
    %{
      id: Ash.UUID.generate(),
      time: now,
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "notification wiring probe",
      log_name: "test",
      log_provider: "test",
      metadata: %{}
    }
  end

  defp synthetic_snapshot(rule) do
    rule
    |> snapshot()
    |> Map.put(:diagnostics, %{
      "latest_source" => %{"source_synthetic_liveness_check" => true}
    })
  end

  defp synthetic_record(now) do
    now
    |> record()
    |> Map.put(:metadata, %{
      "serviceradar" => %{
        "synthetic_liveness_check" => true,
        "anomaly" => %{"series_key" => "probe"}
      }
    })
  end

  defp routing_jobs(alert_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT worker, queue, args
        FROM platform.oban_jobs
        WHERE worker = $1 AND args->>'alert_id' = $2
        ORDER BY id
        """,
        [@routing_worker, alert_id]
      )

    Enum.map(rows, fn [worker, queue, args] ->
      %{"worker" => worker, "queue" => queue, "args" => args}
    end)
  end
end
