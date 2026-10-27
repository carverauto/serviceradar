defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsProcessBatchDBTest do
  use ServiceRadar.DataCase, async: false

  alias Broadway.Message
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.AnomalyEpisodeGuardTables
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry
  alias ServiceRadar.Observability.AlertEvaluationWork
  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Owner
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  defmodule AlertEngine do
    @moduledoc false

    def evaluate_events(events) do
      send(test_pid(), {:alert_evaluation_events, events})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule NorthboundRunner do
    @moduledoc false

    def handle_event(event) do
      send(test_pid(), {:northbound_event, event})
      {:ok, []}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule FailingNorthboundRunner do
    @moduledoc false

    def handle_event(_event), do: raise("northbound runner unavailable")
  end

  defmodule PeerReadinessGatedAlertEngine do
    @moduledoc false

    def evaluate_events(events) do
      case Application.get_env(:serviceradar_core, :analytics_signals_peer_ready, false) do
        true -> StatefulAlertEngine.evaluate_events(events)
        false -> {:error, :alert_evaluation_peer_not_ready}
        {:error, _} = error -> error
      end
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_logger_level = Logger.level()
    Logger.configure(level: :info)

    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_engine)

    previous_northbound_runner =
      Application.get_env(:serviceradar_core, :northbound_event_handler_runner)

    previous_test_pid =
      Application.get_env(:serviceradar_core, :analytics_signals_process_batch_test_pid)

    previous_episodes = Application.get_env(:serviceradar_core, :anomaly_episodes_enabled)

    previous_stale_after =
      Application.get_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    previous_rate_limit =
      Application.get_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour)

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.AlertEngine
    )

    Application.put_env(
      :serviceradar_core,
      :northbound_event_handler_runner,
      __MODULE__.NorthboundRunner
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_process_batch_test_pid,
      self()
    )

    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, true)
    Application.put_env(:serviceradar_core, :anomaly_episode_stale_after_minutes, 30)

    if !Process.whereis(AnomalyEpisodeGuardTables),
      do: start_supervised!(AnomalyEpisodeGuardTables)

    AnomalyEpisodeRegistry.reset_rate_guard!()
    AnomalyEpisodeRegistry.reset_tripwire!()

    on_exit(fn ->
      Logger.configure(level: previous_logger_level)
      restore_env(:stateful_alert_engine, previous_queue)
      restore_env(:northbound_event_handler_runner, previous_northbound_runner)
      restore_env(:analytics_signals_process_batch_test_pid, previous_test_pid)
      restore_env(:anomaly_episodes_enabled, previous_episodes)
      restore_env(:anomaly_episode_stale_after_minutes, previous_stale_after)
      restore_env(:anomaly_episode_rate_limit_per_hour, previous_rate_limit)
      AnomalyEpisodeRegistry.reset_rate_guard!()
      AnomalyEpisodeRegistry.reset_tripwire!()
    end)
  end

  test "bulk recorded causal predictions skip duplicate delivery without alert re-enqueue" do
    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, false)

    message = anomaly_message()
    row = AnalyticsSignals.parse_message(message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1

    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.id == uuid_string(row.id)
    assert alert_row.metadata["event_identity"] == row.metadata["event_identity"]

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1
    refute_receive {:alert_evaluation_events, _}, 100
  end

  test "inventory vulnerability assessment opens, resolves, and reopens one OCSF row" do
    event_id = "assessment-lifecycle-#{System.unique_integer([:positive])}"
    open_message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(open_message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([open_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["open", 1, "Create"]

    assert_receive {:alert_evaluation_events, [open_alert_row]}
    assert open_alert_row.status == "open"

    assert_receive {:northbound_event, open_northbound_row}
    assert open_northbound_row.id == uuid_string(row.id)
    assert open_northbound_row.status == "open"
    assert open_northbound_row.activity_name == "Create"

    assert {:ok, 1} = AnalyticsSignals.process_batch([open_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100

    resolved_message =
      assessment_message(event_id, "resolved", "resolved", "confirmed", "fixed")

    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["resolved", 3, "Close"]

    assert_receive {:alert_evaluation_events, [resolved_alert_row]}
    assert resolved_alert_row.status == "resolved"

    assert_receive {:northbound_event, resolved_northbound_row}
    assert resolved_northbound_row.id == uuid_string(row.id)
    assert resolved_northbound_row.status == "resolved"
    assert resolved_northbound_row.activity_name == "Close"

    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100

    reopened_message = assessment_message(event_id, "open", "active", "confirmed", "affected")

    assert {:ok, 1} = AnalyticsSignals.process_batch([reopened_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["open", 2, "Update"]

    assert_receive {:alert_evaluation_events, [reopened_alert_row]}
    assert reopened_alert_row.status == "open"

    assert_receive {:northbound_event, reopened_northbound_row}
    assert reopened_northbound_row.id == uuid_string(row.id)
    assert reopened_northbound_row.status == "open"
    assert reopened_northbound_row.activity_name == "Update"

    assert {:ok, 1} = AnalyticsSignals.process_batch([reopened_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100
  end

  describe "versioned assessment findings apply in version order, not arrival order" do
    setup do
      event_id = "assessment-versioned-#{System.unique_integer([:positive])}"
      first_seen_at = DateTime.truncate(DateTime.utc_now(), :microsecond)
      opened = DateTime.shift(first_seen_at, second: 1)

      message = fn status, version ->
        versioned_assessment_message(event_id, status, version, first_seen_at)
      end

      row = AnalyticsSignals.parse_message(message.("open", opened))
      delete_event!(row)
      on_exit(fn -> delete_event!(row) end)

      {:ok, message: message, row: row, opened: opened}
    end

    test "a close processed before its open keeps the finding closed", ctx do
      closed = DateTime.shift(ctx.opened, second: 1)

      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("resolved", closed)])
      assert event_lifecycle(ctx.row) == ["resolved", 3, "Close"]

      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("open", ctx.opened)])
      assert event_count(ctx.row) == 1
      assert event_lifecycle(ctx.row) == ["resolved", 3, "Close"]
    end

    test "a stale open delivered after the close cannot reopen it", ctx do
      closed = DateTime.shift(ctx.opened, second: 1)

      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("open", ctx.opened)])
      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("resolved", closed)])
      assert event_lifecycle(ctx.row) == ["resolved", 3, "Close"]

      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("open", ctx.opened)])
      assert event_lifecycle(ctx.row) == ["resolved", 3, "Close"]

      # Both in one batch, the open delivered last.
      assert {:ok, 2} =
               AnalyticsSignals.process_batch([
                 ctx.message.("resolved", closed),
                 ctx.message.("open", ctx.opened)
               ])

      assert event_lifecycle(ctx.row) == ["resolved", 3, "Close"]
    end

    test "a newer open after a close reopens the finding", ctx do
      closed = DateTime.shift(ctx.opened, second: 1)
      reopened = DateTime.shift(closed, second: 1)

      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("resolved", closed)])
      assert {:ok, 1} = AnalyticsSignals.process_batch([ctx.message.("open", reopened)])
      assert event_count(ctx.row) == 1
      assert event_lifecycle(ctx.row) == ["open", 2, "Update"]
    end
  end

  test "real durable admission preserves distinct transitions sharing an event row" do
    mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)
    Application.put_env(:serviceradar_core, :stateful_alert_engine, StatefulAlertEngine)
    on_exit(fn -> restore_env(:alert_evaluation_mode, mode) end)
    Repo.query!("UPDATE platform.stateful_alert_rules SET enabled = FALSE")
    actor = SystemActor.system(:alert_engine)

    rule =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-transition-#{Ash.UUID.generate()}",
          signal: :event,
          match: %{"always" => true},
          group_by: [],
          threshold: 100,
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    identity = "synthetic-assessment-#{Ash.UUID.generate()}"
    opened = assessment_message(identity, "open", "active", "confirmed", "affected")
    cleared = assessment_message(identity, "resolved", "resolved", "confirmed", "fixed")

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert {:ok, 1} = AnalyticsSignals.process_batch([cleared])
    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])

    assert [first, second, third] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.Query.sort(position: :asc)
             |> Ash.read!(actor: actor)

    assert Enum.map([first, second, third], & &1.position) == [1, 2, 3]
    assert length(Enum.uniq(Enum.map([first, second, third], & &1.source_key))) == 3
    assert length(Enum.uniq(Enum.map([first, second, third], & &1.payload["id"]))) == 1

    assert [] =
             StatefulAlertRuleState
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "a rejected transition stays replayable and its retry is admitted once" do
    mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)
    limits = Application.get_env(:serviceradar_core, :alert_evaluation_limits)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)
    Application.put_env(:serviceradar_core, :stateful_alert_engine, StatefulAlertEngine)
    Application.put_env(:serviceradar_core, :alert_evaluation_limits, pending_count: 1)

    on_exit(fn ->
      restore_env(:alert_evaluation_mode, mode)
      restore_env(:alert_evaluation_limits, limits)
    end)

    Repo.query!("UPDATE platform.stateful_alert_rules SET enabled = FALSE")
    actor = SystemActor.system(:alert_engine)

    rule =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-rejection-#{Ash.UUID.generate()}",
          signal: :event,
          match: %{"always" => true},
          group_by: [],
          threshold: 100,
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    assert {:ok, [_]} =
             Inbox.admit(:event, [
               %{
                 id: Ash.UUID.generate(),
                 time: DateTime.utc_now(),
                 message: "synthetic capacity holder"
               }
             ])

    message =
      assessment_message(
        "synthetic-retry-#{Ash.UUID.generate()}",
        "open",
        "active",
        "confirmed",
        "affected"
      )

    row = AnalyticsSignals.parse_message(message)
    assert {:error, _} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 0
    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert {:ok, 1} = AnalyticsSignals.process_batch([message])

    assert [%{position: 2}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert event_count(row) == 1
  end

  test "alert_evaluation_peer_not_ready nacks analytics predictions with delayed backoff and processes once ready (#6062)" do
    mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)
    peer_ready = Application.get_env(:serviceradar_core, :analytics_signals_peer_ready)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :active)

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.PeerReadinessGatedAlertEngine
    )

    Application.put_env(:serviceradar_core, :analytics_signals_peer_ready, false)

    series_key = "synthetic:peer-not-ready:#{System.unique_integer([:positive])}"
    event_id = "prediction-peer-not-ready-#{System.unique_integer([:positive])}"
    raw_message = anomaly_message(series_key, event_id)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      restore_env(:alert_evaluation_mode, mode)
      restore_env(:analytics_signals_peer_ready, peer_ready)
      delete_episode_fixture!(series_key)
    end)

    Repo.query!("UPDATE platform.stateful_alert_rules SET enabled = FALSE")
    actor = SystemActor.system(:alert_engine)

    rule =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-peer-readiness-#{Ash.UUID.generate()}",
          signal: :event,
          match: %{"always" => true},
          group_by: [],
          threshold: 100,
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    parent = self()

    broadway_message = %Message{
      data: raw_message.data,
      metadata:
        Map.merge(raw_message.metadata, %{
          reply_to: "$JS.ACK.analytics_predictions.consumer.1.1.1.0.0",
          jetstream_ack: %{
            stream: "analytics_predictions",
            consumer: "consumer",
            delivery_count: 1
          },
          max_deliver: 5
        }),
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn action ->
             send(parent, {:jetstream_ack, action})
             :ok
           end
         }}
    }

    for {delivery_count, delay_ms} <- [{1, 10_000}, {2, 20_000}, {3, 40_000}] do
      message = put_in(broadway_message.metadata.jetstream_ack.delivery_count, delivery_count)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert [%Message{status: {:failed, :alert_evaluation_peer_not_ready}} = failed_msg] =
                   Pipeline.handle_batch(
                     :analytics_predictions,
                     [message],
                     %{batch_key: :default},
                     %{}
                   )

          assert ^failed_msg = hd(Pipeline.handle_failed([failed_msg], %{}))
          assert :ok = Pipeline.ack(:ack_ref, [], [failed_msg])
        end)

      assert_receive {:jetstream_ack, {:nack, ^delay_ms}}
      refute_receive {:jetstream_ack, :ack}, 50
      refute_receive {:jetstream_ack, :term}, 50

      assert log =~ "Deferring causal signals batch until alert evaluation is ready"
      assert log =~ "Batch deferred until alert evaluation is ready"
      assert log =~ "[info]"
      refute log =~ "[warning]"
      refute log =~ "[error]"
      refute log =~ "MatchError"
      refute log =~ "Causal signals batch insert failed"

      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM platform.anomaly_episodes WHERE series_key = $1",
                 [series_key]
               ).rows

      assert [[0]] =
               Repo.query!(
                 """
                 SELECT count(*)
                 FROM platform.ocsf_events
                 WHERE metadata->'service_radar'->>'series_key' = $1
                 """,
                 [series_key]
               ).rows

      assert [] =
               AlertEvaluationWork
               |> Ash.Query.filter(rule_id == ^rule.id)
               |> Ash.read!(actor: actor)
    end

    message = put_in(broadway_message.metadata.jetstream_ack.delivery_count, 5)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert [%Message{status: {:failed, :alert_evaluation_peer_not_ready}} = failed_msg] =
                 Pipeline.handle_batch(
                   :analytics_predictions,
                   [message],
                   %{batch_key: :default},
                   %{}
                 )

        Pipeline.handle_failed([failed_msg], %{})
        assert :ok = Pipeline.ack(:ack_ref, [], [failed_msg])
      end)

    assert_receive {:jetstream_ack, :term}
    assert log =~ "[error]"
    assert log =~ "EventWriter message reached terminal JetStream delivery"

    Application.put_env(:serviceradar_core, :analytics_signals_peer_ready, true)
    broadway_message = put_in(broadway_message.metadata.jetstream_ack.delivery_count, 4)

    assert [%Message{status: :ok} = ok_msg] =
             Pipeline.handle_batch(
               :analytics_predictions,
               [broadway_message],
               %{batch_key: :default},
               %{}
             )

    assert :ok = Pipeline.ack(:ack_ref, [ok_msg], [])
    assert_receive {:jetstream_ack, :ack}

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM platform.anomaly_episodes WHERE series_key = $1",
               [series_key]
             ).rows

    assert [[1]] =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'series_key' = $1
               """,
               [series_key]
             ).rows

    assert [%{position: 1}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "non-readiness errors in analytics predictions still log error and use immediate nack (#6062)" do
    peer_ready = Application.get_env(:serviceradar_core, :analytics_signals_peer_ready)

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.PeerReadinessGatedAlertEngine
    )

    series_key = "synthetic:non-readiness:#{System.unique_integer([:positive])}"
    event_id = "prediction-non-readiness-#{System.unique_integer([:positive])}"
    raw_message = anomaly_message(series_key, event_id)

    on_exit(fn ->
      restore_env(:analytics_signals_peer_ready, peer_ready)
      delete_episode_fixture!(series_key)
    end)

    parent = self()

    broadway_message = %Message{
      data: raw_message.data,
      metadata:
        Map.merge(raw_message.metadata, %{
          reply_to: "$JS.ACK.analytics_predictions.consumer.1.1.1.0.0",
          jetstream_ack: %{
            stream: "analytics_predictions",
            consumer: "consumer",
            delivery_count: 1
          },
          max_deliver: 5
        }),
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn action ->
             send(parent, {:jetstream_ack, action})
             :ok
           end
         }}
    }

    for reason <- [
          :alert_evaluation_draining,
          :alert_evaluation_capability_unavailable,
          :db_unavailable
        ],
        delivery_count <- 1..5 do
      Application.put_env(:serviceradar_core, :analytics_signals_peer_ready, {:error, reason})
      message = put_in(broadway_message.metadata.jetstream_ack.delivery_count, delivery_count)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert [%Message{status: {:failed, ^reason}} = failed_msg] =
                   Pipeline.handle_batch(
                     :analytics_predictions,
                     [message],
                     %{batch_key: :default},
                     %{}
                   )

          Pipeline.handle_failed([failed_msg], %{})
          assert :ok = Pipeline.ack(:ack_ref, [], [failed_msg])
        end)

      action = if delivery_count == 5, do: :term, else: :nack
      assert_receive {:jetstream_ack, ^action}
      assert log =~ "[error]"
      assert log =~ "Batch processing failed"
      refute log =~ "Batch deferred"
    end
  end

  # Prepared mode admits nothing, by design. A transition commits together with
  # its admission, so every batch carrying one used to roll back, and JetStream
  # dropped it after max_deliver.
  test "prepared alert evaluation stores the transition and admits nothing" do
    mode = Application.get_env(:serviceradar_core, :alert_evaluation_mode)
    Application.put_env(:serviceradar_core, :alert_evaluation_mode, :prepared)
    Application.put_env(:serviceradar_core, :stateful_alert_engine, StatefulAlertEngine)
    on_exit(fn -> restore_env(:alert_evaluation_mode, mode) end)
    Repo.query!("UPDATE platform.stateful_alert_rules SET enabled = FALSE")
    actor = SystemActor.system(:alert_engine)

    rule =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "synthetic-prepared-#{Ash.UUID.generate()}",
          signal: :event,
          match: %{"always" => true},
          group_by: [],
          threshold: 100,
          window_seconds: 120,
          bucket_seconds: 60
        },
        actor: actor
      )
      |> Ash.create!()

    message =
      assessment_message(
        "synthetic-prepared-#{Ash.UUID.generate()}",
        "open",
        "active",
        "confirmed",
        "affected"
      )

    row = AnalyticsSignals.parse_message(message)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1

    assert [] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "northbound runner failure does not suppress the durable alert transition" do
    Application.put_env(
      :serviceradar_core,
      :northbound_event_handler_runner,
      __MODULE__.FailingNorthboundRunner
    )

    event_id = "assessment-runner-failure-#{System.unique_integer([:positive])}"
    message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1
    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.status == "open"
  end

  test "a multi-assessment batch takes one advisory-lock statement" do
    suffix = System.unique_integer([:positive])

    messages =
      for i <- 1..5 do
        assessment_message(
          "assessment-batch-locks-#{suffix}-#{i}",
          "open",
          "active",
          "confirmed",
          "affected"
        )
      end

    rows = Enum.map(messages, &AnalyticsSignals.parse_message/1)

    Enum.each(rows, fn row -> delete_event!(row) end)
    on_exit(fn -> Enum.each(rows, &delete_event!/1) end)

    # The lock statement count must scale with chunks, not rows: one batch,
    # one statement, however many assessments it carries.
    assert {1, {:ok, 5}} =
             count_lock_statements(fn -> AnalyticsSignals.process_batch(messages) end)
  end

  defp count_lock_statements(fun) do
    test_pid = self()
    handler_id = {:lock_statement_count, make_ref()}

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid and String.contains?(query, "pg_advisory") do
          send(test_pid, :advisory_statement)
        end
      end,
      nil
    )

    try do
      result = fun.()

      count = drain_advisory_statements(0)
      {count, result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_advisory_statements(n) do
    receive do
      :advisory_statement -> drain_advisory_statements(n + 1)
    after
      0 -> n
    end
  end

  @tag sandbox: :unboxed
  test "concurrent duplicate opens serialize and dispatch one durable transition" do
    event_id = "assessment-concurrent-open-#{System.unique_integer([:positive])}"
    message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(message)
    event_uuid = uuid_string(row.id)
    parent = self()

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["serviceradar:inventory-vulnerability-lifecycle:#{event_uuid}"]
          )

          send(parent, :inventory_vulnerability_lock_held)

          receive do
            :release_inventory_vulnerability_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release inventory vulnerability lock"
          end
        end)
      end)

    assert_receive :inventory_vulnerability_lock_held, 1_000

    workers =
      for _ <- 1..2 do
        Task.async(fn ->
          result = AnalyticsSignals.process_batch([message])
          send(parent, {:inventory_vulnerability_process_finished, self()})
          result
        end)
      end

    on_exit(fn ->
      send(lock_holder.pid, :release_inventory_vulnerability_lock)

      Enum.each([lock_holder | workers], fn task ->
        if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
      end)
    end)

    refute_receive {:inventory_vulnerability_process_finished, _pid}, 250
    send(lock_holder.pid, :release_inventory_vulnerability_lock)

    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert [{:ok, 1}, {:ok, 1}] = Task.await_many(workers, 5_000)
    assert event_count(row) == 1

    assert_receive {:northbound_event, northbound_row}
    assert northbound_row.id == event_uuid
    assert northbound_row.status == "open"
    refute_receive {:northbound_event, _}, 100

    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.id == event_uuid
    assert alert_row.status == "open"
    refute_receive {:alert_evaluation_events, _}, 100
  end

  test "episode path folds stale producer replays into one transition row and stale-closes" do
    unique = System.unique_integer([:positive])
    series_key = "test-series-episode-fold-#{unique}"
    messages = Enum.map(1..5, &anomaly_message(series_key, "episode-fold-#{unique}-#{&1}"))

    on_exit(fn -> delete_episode_fixture!(series_key) end)
    delete_episode_fixture!(series_key)

    assert {:ok, 5} = AnalyticsSignals.process_batch(messages)

    assert_receive {:alert_evaluation_events, [alert_row]}
    refute_receive {:alert_evaluation_events, _}, 100
    assert alert_row.metadata["service_radar"]["transition"] == "open"

    assert [[episode_uid, 5, "open", "open"]] =
             Repo.query!(
               """
               SELECT episode_uid, occurrence_count, status, last_transition
               FROM platform.anomaly_episodes
               WHERE series_key = $1
               """,
               [series_key]
             ).rows

    assert [[1, true, payload_bytes]] =
             Repo.query!(
               """
               SELECT count(*), bool_and(raw_data IS NULL), max(pg_column_size(unmapped))
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'episode_uid' = $1
               """,
               [episode_uid]
             ).rows

    assert payload_bytes < 2_048

    old_seen_at = DateTime.shift(DateTime.utc_now(), hour: -1)

    Repo.query!(
      "UPDATE platform.anomaly_episodes SET last_seen_at = $2 WHERE series_key = $1",
      [series_key, old_seen_at]
    )

    assert :ok = AnomalyEpisodeStaleCloseWorker.perform(%Oban.Job{})

    assert [["stale_closed", "stale"]] =
             Repo.query!(
               "SELECT status, clear_reason FROM platform.anomaly_episodes WHERE series_key = $1",
               [series_key]
             ).rows
  end

  test "episode path rate guard folds over-limit escalation transitions after DB upsert" do
    Application.put_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour, 1)
    attach_governor_telemetry()

    unique = System.unique_integer([:positive])
    series_key = "test-series-rate-guard-#{unique}"

    messages = [
      anomaly_message(series_key, "rate-guard-#{unique}-1", 1_812_456_000_000_000_000, 3),
      anomaly_message(series_key, "rate-guard-#{unique}-2", 1_812_456_000_000_000_000, 4)
    ]

    on_exit(fn -> delete_episode_fixture!(series_key) end)
    delete_episode_fixture!(series_key)

    assert {:ok, 2} = AnalyticsSignals.process_batch(messages)

    assert_receive {:alert_evaluation_events, [alert_row]}
    refute_receive {:alert_evaluation_events, _}, 100
    assert alert_row.metadata["service_radar"]["transition"] == "open"

    assert_receive {:governor, [:serviceradar, :anomaly, :governor], %{count: 1},
                    %{reason: :rate_limited, finding_uid: finding_uid, limit_per_hour: 1}}

    assert is_binary(finding_uid)

    assert [[1, 2, 4]] =
             Repo.query!(
               """
               SELECT
                 count(*),
                 COALESCE(sum(occurrence_count), 0)::bigint,
                 max(peak_severity_id)
               FROM platform.anomaly_episodes
               WHERE series_key = $1
               """,
               [series_key]
             ).rows

    assert [[1]] =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'series_key' = $1
               """,
               [series_key]
             ).rows
  end

  defp anomaly_message do
    subject = "signals.analytics.predictions.test-series-bulk-record"

    payload = %{
      "event_id" => "bulk-recorded-anomaly-#{System.unique_integer([:positive])}",
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => 4,
      "device_uid" => "sr:bulk-record-device",
      "anomaly" => %{
        "series_key" => "test-series-bulk-record",
        "metric_class" => "sysmon.cpu",
        "state" => "anomaly_open",
        "score" => 4.2
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{subject: subject, received_at: DateTime.utc_now()}
    }
  end

  defp versioned_assessment_message(event_id, finding_status, version, first_seen_at) do
    {assessment_status, disposition} =
      if finding_status == "open", do: {"active", "affected"}, else: {"resolved", "fixed"}

    assessment_message(event_id, finding_status, assessment_status, "confirmed", disposition,
      timestamp: first_seen_at,
      version: version
    )
  end

  defp assessment_message(
         event_id,
         finding_status,
         assessment_status,
         assessment,
         disposition,
         opts \\ []
       ) do
    timestamp =
      Keyword.get_lazy(opts, :timestamp, fn ->
        DateTime.truncate(DateTime.utc_now(), :microsecond)
      end)

    payload = %{
      "event_id" => event_id,
      "signal_type" => "inventory",
      "event_type" => "vulnerability_assessment",
      "finding_type" => "vulnerability",
      "finding_version" => opts |> Keyword.get(:version) |> encode_version(),
      "timestamp" => DateTime.to_iso8601(timestamp),
      "device_uid" => "sr:assessment-lifecycle-device",
      "cve_id" => "CVE-2099-9001",
      "status" => finding_status,
      "finding_status" => finding_status,
      "assessment_status" => assessment_status,
      "assessment" => assessment,
      "disposition" => disposition,
      "package" => %{
        "identity_key" => "pkgid:v1:assessment-lifecycle",
        "name" => "starling-fetch",
        "version" => "3.2.1-1ubuntu99.4"
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.inventory.vulnerability_assessment",
        received_at: DateTime.utc_now()
      }
    }
  end

  defp encode_version(nil), do: nil
  defp encode_version(%DateTime{} = version), do: DateTime.to_iso8601(version)

  defp anomaly_message(
         series_key,
         event_id,
         episode_started_at_unix_nano \\ 1_812_456_000_000_000_000,
         severity_id \\ 4
       ) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => severity_id,
      "device_uid" => "sr:episode-fold-device",
      "verdict_source" => "edge-drift",
      "producer_version" => "0.2.0",
      "anomaly" => %{
        "series_key" => series_key,
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "state" => "anomaly_drift_open",
        "score" => 4.2,
        "episode_started_at_unix_nano" => episode_started_at_unix_nano
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.#{series_key}",
        received_at: DateTime.utc_now()
      }
    }
  end

  defp delete_event!(nil), do: :ok

  defp delete_event!(row) do
    Repo.query!(
      "DELETE FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
      [uuid_string(row.id), row.time]
    )

    :ok
  end

  defp delete_episode_fixture!(series_key) do
    Repo.query!(
      """
      DELETE FROM platform.ocsf_events
      WHERE metadata->'service_radar'->>'series_key' = $1
         OR unmapped->'anomaly'->>'series_key' = $1
      """,
      [series_key]
    )

    Repo.query!("DELETE FROM platform.anomaly_episodes WHERE series_key = $1", [series_key])
    :ok
  end

  defp event_count(row) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    count
  end

  defp event_lifecycle(row) do
    %{rows: [[status, activity_id, activity_name]]} =
      Repo.query!(
        "SELECT status, activity_id, activity_name FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    [status, activity_id, activity_name]
  end

  defp uuid_string(<<_::128>> = id) do
    {:ok, uuid} = Ecto.UUID.load(id)
    uuid
  end

  defp uuid_string(id) when is_binary(id) do
    {:ok, uuid} = Ecto.UUID.cast(id)
    uuid
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp attach_governor_telemetry do
    handler_id = {__MODULE__, :governor, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :anomaly, :governor],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:governor, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
