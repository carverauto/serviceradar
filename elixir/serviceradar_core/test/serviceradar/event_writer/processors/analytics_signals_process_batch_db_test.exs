defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsProcessBatchDBTest do
  use ServiceRadar.DataCase, async: false

  alias Broadway.Message
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.AlertAdmissionDrainWorker
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

  defmodule CanonicalBodyEngine do
    @moduledoc false

    def evaluate_events(events) do
      send(test_pid(), {:alert_evaluation_events, events})

      Application.get_env(
        :serviceradar_core,
        :analytics_signals_replay_result,
        {:error, {:overloaded, :rule_bytes}}
      )
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule SaturatedRuleEngine do
    @moduledoc false

    def evaluate_events(events) do
      send(test_pid(), {:alert_evaluation_events, events})

      if Enum.any?(events, &String.starts_with?(&1.message, "saturated-forecast")),
        do: {:error, {:overloaded, :rule_count}},
        else: :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule OneSlotEngine do
    @moduledoc false

    def evaluate_events(events) do
      send(test_pid(), {:alert_evaluation_events, events})

      case Application.get_env(:serviceradar_core, :analytics_signals_admission_slots, 0) do
        slots when is_integer(slots) and slots > 0 ->
          Application.put_env(:serviceradar_core, :analytics_signals_admission_slots, slots - 1)
          :ok

        _ ->
          {:error, {:overloaded, :rule_bytes}}
      end
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
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

  test "every re-entered lifecycle state is a new admitted occurrence" do
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
          name: "synthetic-reentry-#{Ash.UUID.generate()}",
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

    event_id = "synthetic-reentry-#{Ash.UUID.generate()}"
    first_seen = DateTime.truncate(DateTime.utc_now(), :microsecond)

    transitions =
      for {status, step} <- Enum.with_index(~w(open resolved open resolved open), 1) do
        versioned_assessment_message(
          event_id,
          status,
          DateTime.shift(first_seen, second: step),
          first_seen
        )
      end

    row = AnalyticsSignals.parse_message(hd(transitions))

    for message <- transitions do
      assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    end

    assert {"open", 2, "Update", "true"} = stored_finding(row)

    work =
      AlertEvaluationWork
      |> Ash.Query.filter(rule_id == ^rule.id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(work, & &1.position) == [1, 2, 3, 4, 5]
    assert length(Enum.uniq(Enum.map(work, & &1.source_key))) == 5

    assert Enum.map(work, & &1.payload["status"]) ==
             ~w(open resolved open resolved open)
  end

  test "identical unversioned re-entries from distinct stream messages are each admitted" do
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
          name: "synthetic-identical-reentry-#{Ash.UUID.generate()}",
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

    event_id = "synthetic-identical-reentry-#{Ash.UUID.generate()}"
    opened = assessment_message(event_id, "open", "active", "confirmed", "affected")
    resolved = assessment_message(event_id, "resolved", "resolved", "confirmed", "fixed")
    row = AnalyticsSignals.parse_message(opened)

    deliveries =
      [opened, resolved, opened, resolved, opened]
      |> Enum.with_index(1)
      |> Enum.map(fn {message, sequence} ->
        put_in(message, [:metadata, :jetstream_ack], %{
          stream: "synthetic-analytics",
          stream_sequence: sequence
        })
      end)

    for message <- deliveries do
      assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    end

    assert {"open", 2, "Update", "true"} = stored_finding(row)

    work =
      AlertEvaluationWork
      |> Ash.Query.filter(rule_id == ^rule.id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(work, & &1.position) == [1, 2, 3, 4, 5]
    assert length(Enum.uniq(Enum.map(work, & &1.source_key))) == 5
    assert Enum.map(work, & &1.payload["status"]) == ~w(open resolved open resolved open)
  end

  test "the drain admits a pending occurrence whose series gets no later message" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
    end)

    message =
      assessment_message(
        "synthetic-drain-#{Ash.UUID.generate()}",
        "open",
        "active",
        "confirmed",
        "affected"
      )

    row = AnalyticsSignals.parse_message(message)
    event_id = uuid_string(row.id)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert_receive {:alert_evaluation_events, [%{id: ^event_id}]}
    assert pending_occurrence_count(row) == 1

    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    assert_receive {:alert_evaluation_events, [%{id: ^event_id} = still_refused]}
    assert still_refused.activity_name == "Create"
    assert pending_occurrence_count(row) == 1

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    assert_receive {:alert_evaluation_events, [%{id: ^event_id} = admitted]}
    assert admitted.status == "open"
    assert admitted.activity_name == "Create"
    assert pending_occurrence_count(row) == 0

    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    refute_receive {:alert_evaluation_events, [%{id: ^event_id}]}, 50
  end

  test "a redelivery whose own occurrence is admitted is acked while a later one waits" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    stamp = System.unique_integer([:positive])
    series_key = "synthetic:redelivery-tail:#{stamp}"
    earlier_message = "earlier-forecast-#{stamp}"
    later_message = "saturated-forecast-#{stamp}"

    earlier =
      capacity_forecast_message(series_key, "tail-earlier", earlier_message, 1_812_456_000_000)

    later =
      capacity_forecast_message(series_key, "tail-later", later_message, 1_812_456_060_000)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([earlier])
    assert_receive {:alert_evaluation_events, [%{message: ^earlier_message}]}
    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    assert_receive {:alert_evaluation_events, [%{message: ^earlier_message}]}
    assert pending_admission_messages(series_key) == [earlier_message, later_message]

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.SaturatedRuleEngine
    )

    assert {:ok, 1} = AnalyticsSignals.process_batch([earlier])
    assert_receive {:alert_evaluation_events, [%{message: ^earlier_message}]}
    assert_receive {:alert_evaluation_events, [%{message: ^later_message}]}
    assert pending_admission_messages(series_key) == [later_message]
  end

  test "one drain run scans past series stuck behind a saturated rule" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    stamp = System.unique_integer([:positive])
    saturated_message = "saturated-forecast-#{stamp}"
    quiet_forecast = "quiet-forecast-#{stamp}"
    saturated = for n <- 1..4, do: "synthetic:drain-saturated:#{stamp}:#{n}"
    quiet = "synthetic:drain-quiet:#{stamp}"
    series = saturated ++ [quiet]

    Enum.each(series, &delete_episode_fixture!/1)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      Enum.each(series, &delete_episode_fixture!/1)
    end)

    for {series_key, n} <- Enum.with_index(saturated, 1) do
      message =
        capacity_forecast_message(
          series_key,
          "drain-saturated-#{n}",
          saturated_message,
          1_812_456_000_000
        )

      assert {:ok, 1} = AnalyticsSignals.process_batch([message])
      assert_receive {:alert_evaluation_events, [_refused]}
    end

    quiet_message =
      capacity_forecast_message(quiet, "drain-quiet", quiet_forecast, 1_812_456_000_000)

    assert {:ok, 1} = AnalyticsSignals.process_batch([quiet_message])
    assert_receive {:alert_evaluation_events, [_refused]}

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.SaturatedRuleEngine
    )

    # Two full pages of saturated series come before the quiet one.
    assert AnalyticsSignals.drain_pending_admissions(page_size: 2) >= 1

    for _series_key <- saturated do
      assert_receive {:alert_evaluation_events, [%{message: ^saturated_message}]}
    end

    assert_receive {:alert_evaluation_events, [%{message: ^quiet_forecast}]}

    refute_receive {:alert_evaluation_events, [%{message: ^saturated_message}]}, 50
    refute_receive {:alert_evaluation_events, [%{message: ^quiet_forecast}]}, 50

    assert pending_admission_messages(quiet) == []

    for series_key <- saturated do
      assert pending_admission_messages(series_key) == [saturated_message]
    end
  end

  test "a refused transition stays pending and a later delivery admits it once" do
    rule = fill_alert_evaluation_capacity!()

    message =
      assessment_message(
        "synthetic-retry-#{Ash.UUID.generate()}",
        "open",
        "active",
        "confirmed",
        "affected"
      )

    row = AnalyticsSignals.parse_message(message)
    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1

    assert [%{position: 1}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: SystemActor.system(:alert_engine))

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert {:ok, 1} = AnalyticsSignals.process_batch([message])

    assert [%{position: 2, source_key: source_key}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: SystemActor.system(:alert_engine))

    assert is_binary(source_key)
    assert event_count(row) == 1
  end

  test "an overloaded final delivery is acknowledged and its transition stays pending" do
    rule = fill_alert_evaluation_capacity!()
    parent = self()

    raw =
      assessment_message(
        "synthetic-final-#{Ash.UUID.generate()}",
        "open",
        "active",
        "confirmed",
        "affected"
      )

    message = %Message{
      data: raw.data,
      metadata:
        Map.merge(raw.metadata, %{
          jetstream_ack: %{delivery_count: 5},
          max_deliver: 5
        }),
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn action ->
             send(parent, {:ack_action, action})
             :ok
           end
         }}
    }

    row = AnalyticsSignals.parse_message(message)

    assert [%Message{status: :ok} = acked] =
             Pipeline.handle_batch(:causal_signals, [message], %{batch_key: :default}, %{})

    assert :ok = Pipeline.ack(:ack_ref, [acked], [])
    assert_receive {:ack_action, :ack}
    refute_receive {:ack_action, :term}, 50
    refute_receive {:ack_action, {:nack, _delay}}, 50
    assert event_count(row) == 1
    assert pending_occurrence_count(row) == 1

    assert [%{position: 1}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: SystemActor.system(:alert_engine))

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)
    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    assert pending_occurrence_count(row) == 0

    assert [%{position: 2}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: SystemActor.system(:alert_engine))
  end

  test "a refused lifecycle tail acks both messages and a later delivery admits only the tail" do
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
          name: "synthetic-tail-#{Ash.UUID.generate()}",
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

    first =
      broadway_assessment("synthetic-tail-a-#{Ash.UUID.generate()}", parent, :first)

    second =
      broadway_assessment("synthetic-tail-b-#{Ash.UUID.generate()}", parent, :second)

    assert [%Message{status: :ok} = admitted, %Message{status: :ok} = pending] =
             Pipeline.handle_batch(
               :causal_signals,
               [first, second],
               %{batch_key: :default},
               %{}
             )

    assert :ok = Pipeline.ack(:ack_ref, [admitted, pending], [])
    assert_receive {:ack_action, :first, :ack}
    assert_receive {:ack_action, :second, :ack}
    refute_receive {:ack_action, _which, {:nack, _delay}}, 50
    refute_receive {:ack_action, _which, :term}, 50

    assert event_count(AnalyticsSignals.parse_message(first)) == 1
    assert event_count(AnalyticsSignals.parse_message(second)) == 1

    assert [%{source_key: admitted_key, position: 1}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.Query.sort(position: :asc)
             |> Ash.read!(actor: actor)

    assert {:ok, {:processed, :completed}} = Owner.advance(rule.id)

    assert [%Message{status: :ok}] =
             Pipeline.handle_batch(:causal_signals, [second], %{batch_key: :default}, %{})

    assert [%{source_key: tail_key, position: 2}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert tail_key != admitted_key

    assert [%Message{status: :ok}] =
             Pipeline.handle_batch(:causal_signals, [second], %{batch_key: :default}, %{})

    assert [%{source_key: ^tail_key}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)
  end

  test "a later same-series anomaly open admits the persisted transition" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_key = "synthetic:canonical-body:#{System.unique_integer([:positive])}"
    started = 1_812_456_000_000_000_000

    canonical =
      anomaly_open(series_key, "canonical-event", "canonical-open", 4.2, started)

    later = anomaly_open(series_key, "later-event", "later-open", 99.0, started)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([canonical])
    assert_receive {:alert_evaluation_events, [first_event]}
    assert canonical_transition?(first_event)
    assert stored_anomaly(series_key) == {"canonical-open", "canonical-event", "false"}

    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    assert_receive {:alert_evaluation_events, [replayed]}
    assert canonical_transition?(replayed)
    assert stored_anomaly(series_key) == {"canonical-open", "canonical-event", "false"}

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)
    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    assert_receive {:alert_evaluation_events, [admitted]}
    assert canonical_transition?(admitted)
    assert stored_anomaly(series_key) == {"canonical-open", "canonical-event", "true"}

    assert {:ok, 1} = AnalyticsSignals.process_batch([canonical])
    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    refute_receive {:alert_evaluation_events, _events}, 50
    assert stored_anomaly(series_key) == {"canonical-open", "canonical-event", "true"}
  end

  test "a redelivered anomaly transition is tied to its message without stored bookkeeping" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_key = "synthetic:delivered-identity:#{System.unique_integer([:positive])}"

    open =
      anomaly_open(
        series_key,
        "delivered-event",
        "delivered-open",
        4.2,
        1_812_456_000_000_000_000
      )

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([open])
    assert_receive {:alert_evaluation_events, [first]}
    assert {:ok, 1} = AnalyticsSignals.process_batch([open])
    assert_receive {:alert_evaluation_events, [redelivered]}

    for event <- [first, redelivered] do
      refute Map.has_key?(event.metadata["service_radar"], "source_event_identity")
    end

    assert [[service_radar]] =
             Repo.query!(
               """
               SELECT metadata->'service_radar'
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'series_key' = $1
               """,
               [series_key]
             ).rows

    refute Map.has_key?(service_radar, "source_event_identity")

    assert [[occurrence_service_radar]] =
             Repo.query!(
               """
               SELECT occurrence->'metadata'->'service_radar'
               FROM platform.alert_pending_admissions
               WHERE series_key = $1
               """,
               [series_key]
             ).rows

    refute Map.has_key?(occurrence_service_radar, "source_event_identity")

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)
    assert {:ok, 1} = AnalyticsSignals.process_batch([open])
    assert_receive {:alert_evaluation_events, [_admitted]}
    assert pending_admission_messages(series_key) == []
  end

  test "a later series clear waits until the pending open is admitted" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_key = "synthetic:series-order:#{System.unique_integer([:positive])}"
    started = 1_812_456_000_000_000_000

    open = anomaly_open(series_key, "open-event", "series-open", 4.2, started)
    clear = anomaly_clear(series_key, "clear-event", "series-clear", started)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([open])
    assert_receive {:alert_evaluation_events, [opened]}
    assert opened.message == "series-open"
    assert opened.unmapped["event_id"] == "open-event"
    assert stored_series_transitions(series_key) == [{"series-open", "false"}]

    assert {:ok, 1} = AnalyticsSignals.process_batch([clear])
    assert_receive {:alert_evaluation_events, [waiting]}
    assert waiting.message == "series-open"
    assert waiting.unmapped["event_id"] == "open-event"
    refute_receive {:alert_evaluation_events, _events}, 50

    assert stored_series_transitions(series_key) == [
             {"series-open", "false"},
             {"series-clear", "false"}
           ]

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)
    assert {:ok, 1} = AnalyticsSignals.process_batch([clear])
    assert_receive {:alert_evaluation_events, [admitted_open]}
    assert admitted_open.message == "series-open"
    assert admitted_open.unmapped["event_id"] == "open-event"
    assert_receive {:alert_evaluation_events, [admitted_clear]}
    assert admitted_clear.message == "series-clear"
    assert admitted_clear.unmapped["event_id"] == "clear-event"

    assert stored_series_transitions(series_key) == [
             {"series-open", "true"},
             {"series-clear", "true"}
           ]

    assert {:ok, 1} = AnalyticsSignals.process_batch([open])
    assert {:ok, 1} = AnalyticsSignals.process_batch([clear])
    refute_receive {:alert_evaluation_events, _events}, 50
  end

  test "a held forecast redelivery admits the earlier pending series row first" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_key = "synthetic:forecast-order:#{System.unique_integer([:positive])}"

    earlier =
      capacity_forecast_message(series_key, "forecast-a", "forecast-earlier", 1_812_456_000_000)

    later =
      capacity_forecast_message(series_key, "forecast-b", "forecast-later", 1_812_456_060_000)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([earlier])
    assert_receive {:alert_evaluation_events, [first]}
    assert first.message == "forecast-earlier"
    assert pending_admission_messages(series_key) == ["forecast-earlier"]

    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    assert_receive {:alert_evaluation_events, [waiting]}
    assert waiting.message == "forecast-earlier"
    refute_receive {:alert_evaluation_events, _events}, 50
    assert pending_admission_messages(series_key) == ["forecast-earlier", "forecast-later"]

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    assert_receive {:alert_evaluation_events, [admitted_earlier]}
    assert admitted_earlier.message == "forecast-earlier"
    assert_receive {:alert_evaluation_events, [admitted_later]}
    assert admitted_later.message == "forecast-later"
    refute_receive {:alert_evaluation_events, _events}, 50
    assert pending_admission_messages(series_key) == []

    assert {:ok, 1} = AnalyticsSignals.process_batch([later])
    refute_receive {:alert_evaluation_events, _events}, 50
    assert pending_admission_messages(series_key) == []
  end

  test "same-batch forecasts admit the earlier event before the later message" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine, __MODULE__.OneSlotEngine)
    Application.put_env(:serviceradar_core, :analytics_signals_admission_slots, 1)

    series_key = "synthetic:forecast-same-batch:#{System.unique_integer([:positive])}"

    earlier =
      capacity_forecast_message(series_key, "forecast-a", "forecast-earlier", 1_812_456_000_000)

    later =
      capacity_forecast_message(series_key, "forecast-b", "forecast-later", 1_812_456_060_000)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_admission_slots)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 2} = AnalyticsSignals.process_batch([later, earlier])

    assert_receive {:alert_evaluation_events, [admitted]}
    assert admitted.message == "forecast-earlier"
    assert_receive {:alert_evaluation_events, [refused]}
    assert refused.message == "forecast-later"
    refute_receive {:alert_evaluation_events, _events}, 50

    assert stored_series_transitions(series_key) == [
             {"forecast-earlier", "true"},
             {"forecast-later", "false"}
           ]

    assert pending_admission_messages(series_key) == ["forecast-later"]
  end

  test "different series in one batch admit in message order" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine, __MODULE__.OneSlotEngine)
    Application.put_env(:serviceradar_core, :analytics_signals_admission_slots, 1)

    first_series = "synthetic:forecast-series-a:#{System.unique_integer([:positive])}"
    second_series = "synthetic:forecast-series-b:#{System.unique_integer([:positive])}"

    first =
      capacity_forecast_message(first_series, "forecast-a", "forecast-first", 1_812_456_060_000)

    second =
      capacity_forecast_message(second_series, "forecast-b", "forecast-second", 1_812_456_000_000)

    delete_episode_fixture!(first_series)
    delete_episode_fixture!(second_series)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_admission_slots)
      delete_episode_fixture!(first_series)
      delete_episode_fixture!(second_series)
    end)

    assert {:ok, 2} = AnalyticsSignals.process_batch([first, second])

    assert_receive {:alert_evaluation_events, [admitted]}
    assert admitted.message == "forecast-first"
    assert_receive {:alert_evaluation_events, [refused]}
    assert refused.message == "forecast-second"
    refute_receive {:alert_evaluation_events, _events}, 50

    assert pending_admission_messages(first_series) == []
    assert pending_admission_messages(second_series) == ["forecast-second"]
  end

  test "a pending forecast between two same-batch forecasts is admitted first" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_key = "synthetic:forecast-gap:#{System.unique_integer([:positive])}"

    earlier =
      capacity_forecast_message(series_key, "forecast-t1", "forecast-t1", 1_812_456_000_000)

    middle =
      capacity_forecast_message(series_key, "forecast-t2", "forecast-t2", 1_812_456_030_000)

    later = capacity_forecast_message(series_key, "forecast-t3", "forecast-t3", 1_812_456_060_000)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_episode_fixture!(series_key)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([middle])
    assert_receive {:alert_evaluation_events, [waiting]}
    assert waiting.message == "forecast-t2"
    assert pending_admission_messages(series_key) == ["forecast-t2"]

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    # The pending forecast arrived first, so it keeps its FIFO place ahead of
    # the batch's own forecasts, which follow in event-time order.
    assert {:ok, 2} = AnalyticsSignals.process_batch([later, earlier])
    assert_receive {:alert_evaluation_events, [admitted_middle]}
    assert admitted_middle.message == "forecast-t2"
    assert_receive {:alert_evaluation_events, [admitted_earlier]}
    assert admitted_earlier.message == "forecast-t1"
    assert_receive {:alert_evaluation_events, [admitted_later]}
    assert admitted_later.message == "forecast-t3"
    refute_receive {:alert_evaluation_events, _events}, 50

    assert stored_series_transitions(series_key) == [
             {"forecast-t1", "true"},
             {"forecast-t2", "true"},
             {"forecast-t3", "true"}
           ]

    assert pending_admission_messages(series_key) == []
  end

  test "same-time forecasts admit in pending insert order" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    series_prefix = "synthetic:forecast-inserted-at:#{System.unique_integer([:positive])}"
    attempt_keys = Enum.map(1..40, &"#{series_prefix}:#{&1}")
    time = 1_812_456_000_000

    Enum.each(attempt_keys, &delete_episode_fixture!/1)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      Enum.each(attempt_keys, &delete_episode_fixture!/1)
    end)

    # A pending row's event_id is the episode transition identity, derived from
    # the series and time rather than the message's own event_id, so each
    # attempt needs a fresh series to draw a different id pair.
    {series_key, newer} =
      Enum.find_value(attempt_keys, fn series_key ->
        older = capacity_forecast_message(series_key, "forecast-older", "forecast-older", time)
        newer = capacity_forecast_message(series_key, "forecast-newer", "forecast-newer", time)

        assert {:ok, 1} = AnalyticsSignals.process_batch([older])
        assert_receive {:alert_evaluation_events, [_ignored]}
        assert {:ok, 1} = AnalyticsSignals.process_batch([newer])
        assert_receive {:alert_evaluation_events, [_ignored]}
        refute_receive {:alert_evaluation_events, _events}, 50

        case pending_admission_ids(series_key) do
          [{_, first_id}, {_, second_id}] when first_id > second_id -> {series_key, newer}
          _ -> nil
        end
      end) || flunk("no same-time forecast pair inverted event-id order")

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    assert {:ok, 1} = AnalyticsSignals.process_batch([newer])
    assert_receive {:alert_evaluation_events, [admitted_older]}
    assert admitted_older.message == "forecast-older"
    assert_receive {:alert_evaluation_events, [admitted_newer]}
    assert admitted_newer.message == "forecast-newer"
    refute_receive {:alert_evaluation_events, _events}, 50
    assert pending_admission_messages(series_key) == []
  end

  test "same-time forecasts in one batch admit in message order" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine, __MODULE__.OneSlotEngine)
    Application.put_env(:serviceradar_core, :analytics_signals_admission_slots, 1)

    series_key = "synthetic:forecast-same-time-batch:#{System.unique_integer([:positive])}"
    time = 1_812_456_000_000
    earlier = capacity_forecast_message(series_key, "forecast-earlier", "forecast-earlier", time)

    delete_episode_fixture!(series_key)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_admission_slots)
      delete_episode_fixture!(series_key)
    end)

    {earlier, later} =
      Enum.find_value(1..80, fn n ->
        later =
          capacity_forecast_message(series_key, "forecast-later-#{n}", "forecast-later", time)

        if forecast_event_id(later) < forecast_event_id(earlier) do
          {earlier, later}
        end
      end) || flunk("no same-time forecast pair inverted event-id order")

    assert forecast_event_id(later) < forecast_event_id(earlier)

    assert {:ok, 2} = AnalyticsSignals.process_batch([earlier, later])

    assert_receive {:alert_evaluation_events, [admitted]}
    assert admitted.message == "forecast-earlier"
    assert_receive {:alert_evaluation_events, [refused]}
    assert refused.message == "forecast-later"
    refute_receive {:alert_evaluation_events, _events}, 50

    assert Map.new(stored_series_transitions(series_key)) == %{
             "forecast-earlier" => "true",
             "forecast-later" => "false"
           }

    assert pending_admission_messages(series_key) == ["forecast-later"]
  end

  test "a newer inventory close queues behind the pending open and survives repeated refusals" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    event_id = "synthetic-inventory-pending-#{System.unique_integer([:positive])}"
    first_seen = DateTime.truncate(DateTime.utc_now(), :microsecond)
    open_version = DateTime.shift(first_seen, second: 1)
    resolved_version = DateTime.shift(open_version, second: 1)
    opened = versioned_assessment_message(event_id, "open", open_version, first_seen)
    resolved = versioned_assessment_message(event_id, "resolved", resolved_version, first_seen)
    row = AnalyticsSignals.parse_message(opened)

    delete_event!(row)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_event!(row)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert_receive {:alert_evaluation_events, [open_event]}
    assert open_event.status == "open"
    assert open_event.activity_name == "Create"
    assert_receive {:northbound_event, _}
    assert stored_finding(row) == {"open", 1, "Create", "false"}

    # Every delivery of the close is refused. Each is acknowledged, and the
    # close is stored on its first delivery and queues behind the open, which
    # keeps being retried first.
    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved])
    assert_receive {:alert_evaluation_events, [blocked_open]}
    assert blocked_open.status == "open"
    assert blocked_open.activity_name == "Create"
    assert_receive {:northbound_event, northbound_close}
    assert northbound_close.status == "resolved"

    for _redelivery <- 2..5 do
      assert {:ok, 1} = AnalyticsSignals.process_batch([resolved])
      assert_receive {:alert_evaluation_events, [retried_open]}
      assert retried_open.activity_name == "Create"
    end

    refute_receive {:alert_evaluation_events, _events}, 50
    refute_receive {:northbound_event, _event}, 50
    assert stored_finding(row) == {"resolved", 3, "Close", "false"}
    assert pending_occurrence_count(row) == 2
    refute Map.has_key?(stored_metadata(row), "alert_evaluation_admitted")
    refute Map.has_key?(stored_metadata(row), "alert_evaluation_occurrence_id")

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    # A later message for the same finding admits the pending tail in order,
    # each occurrence with the payload it had when it was stored.
    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert_receive {:alert_evaluation_events, [admitted_open]}
    assert admitted_open.status == "open"
    assert admitted_open.activity_name == "Create"
    assert_receive {:alert_evaluation_events, [admitted_close]}
    assert admitted_close.status == "resolved"
    assert admitted_close.activity_name == "Close"
    refute_receive {:alert_evaluation_events, _events}, 50
    refute_receive {:northbound_event, _event}, 50
    assert stored_finding(row) == {"resolved", 3, "Close", "true"}
    assert pending_occurrence_count(row) == 0

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved])
    refute_receive {:alert_evaluation_events, _events}, 50
    assert stored_finding(row) == {"resolved", 3, "Close", "true"}
  end

  test "a versioned inventory update during a pending admission keeps the open's own payload" do
    Application.put_env(
      :serviceradar_core,
      :stateful_alert_engine,
      __MODULE__.CanonicalBodyEngine
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_replay_result,
      {:error, {:overloaded, :rule_bytes}}
    )

    event_id = "synthetic-inventory-version-#{System.unique_integer([:positive])}"
    first_seen = DateTime.truncate(DateTime.utc_now(), :microsecond)
    version = DateTime.shift(first_seen, second: 1)
    later = DateTime.shift(version, second: 1)
    opened = versioned_assessment_message(event_id, "open", version, first_seen)
    updated = versioned_assessment_message(event_id, "open", later, first_seen)
    row = AnalyticsSignals.parse_message(opened)

    delete_event!(row)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :analytics_signals_replay_result)
      delete_event!(row)
    end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert_receive {:alert_evaluation_events, [open_event]}
    assert open_event.status == "open"
    assert_receive {:northbound_event, _}
    assert stored_finding(row) == {"open", 1, "Create", "false"}
    assert stored_finding_version(row) == DateTime.to_iso8601(version)

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    assert_receive {:alert_evaluation_events, [replayed]}
    assert replayed.status == "open"
    assert replayed.activity_name == "Create"
    refute_receive {:northbound_event, _event}, 50
    assert stored_finding(row) == {"open", 1, "Create", "false"}

    Application.put_env(:serviceradar_core, :analytics_signals_replay_result, :ok)

    assert {:ok, 1} = AnalyticsSignals.process_batch([updated])
    assert_receive {:alert_evaluation_events, [admitted_open]}
    assert admitted_open.status == "open"
    assert admitted_open.activity_name == "Create"
    refute_receive {:alert_evaluation_events, _events}, 50
    refute_receive {:northbound_event, _event}, 50
    assert stored_finding(row) == {"open", 2, "Update", "true"}
    assert stored_finding_version(row) == DateTime.to_iso8601(later)

    assert {:ok, 1} = AnalyticsSignals.process_batch([opened])
    refute_receive {:alert_evaluation_events, _events}, 50
    assert stored_finding_version(row) == DateTime.to_iso8601(later)

    assert {:ok, 1} = AnalyticsSignals.process_batch([updated])
    refute_receive {:alert_evaluation_events, _events}, 50
    assert stored_finding(row) == {"open", 2, "Update", "true"}
  end

  # Activates the real engine with room for one pending occurrence and takes it,
  # so the next admission is refused as overloaded.
  defp fill_alert_evaluation_capacity! do
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

    rule
  end

  test "alert_evaluation_peer_not_ready acks analytics predictions at every delivery and the drain admits them once ready (#6062)" do
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

    # Every delivery, the final one included, is acknowledged: the refused
    # admission waits in the durable backlog instead of in JetStream.
    for delivery_count <- [1, 5] do
      message = put_in(broadway_message.metadata.jetstream_ack.delivery_count, delivery_count)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert [%Message{status: :ok} = acked] =
                   Pipeline.handle_batch(
                     :analytics_predictions,
                     [message],
                     %{batch_key: :default},
                     %{}
                   )

          assert :ok = Pipeline.ack(:ack_ref, [acked], [])
        end)

      assert_receive {:jetstream_ack, :ack}
      refute_receive {:jetstream_ack, {:nack, _delay}}, 50
      refute_receive {:jetstream_ack, :term}, 50
      refute log =~ "[warning]"
      refute log =~ "[error]"
      refute log =~ "terminal JetStream delivery"

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

      assert [] =
               AlertEvaluationWork
               |> Ash.Query.filter(rule_id == ^rule.id)
               |> Ash.read!(actor: actor)
    end

    Application.put_env(:serviceradar_core, :analytics_signals_peer_ready, true)
    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})

    assert [%{position: 1}] =
             AlertEvaluationWork
             |> Ash.Query.filter(rule_id == ^rule.id)
             |> Ash.read!(actor: actor)

    assert :ok = AlertAdmissionDrainWorker.perform(%Oban.Job{args: %{}})

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
    end
  end

  # Prepared mode admits nothing, by design. The transition still commits, so
  # the signal is stored while alert rules are not evaluating.
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

  defp broadway_assessment(event_id, parent, tag) do
    raw = assessment_message(event_id, "open", "active", "confirmed", "affected")

    %Message{
      data: raw.data,
      metadata: raw.metadata,
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn action ->
             send(parent, {:ack_action, tag, action})
             :ok
           end
         }}
    }
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

  defp anomaly_open(series_key, event_id, message, score, started) do
    raw = anomaly_message(series_key, event_id, started)

    payload =
      raw.data
      |> Jason.decode!()
      |> Map.put("message", message)
      |> put_in(["anomaly", "score"], score)

    %{raw | data: Jason.encode!(payload)}
  end

  defp anomaly_clear(series_key, event_id, message, started) do
    raw = anomaly_message(series_key, event_id, started)

    payload =
      raw.data
      |> Jason.decode!()
      |> Map.put("message", message)
      |> Map.put("time", 1_812_456_060_000)
      |> put_in(["anomaly", "state"], "anomaly_drift_clear")

    %{raw | data: Jason.encode!(payload)}
  end

  defp canonical_transition?(event) do
    event.message == "canonical-open" and event.unmapped["event_id"] == "canonical-event" and
      canonical_score?(get_in(event.unmapped, ["anomaly", "score"]))
  end

  defp canonical_score?(score) when is_float(score), do: abs(score - 4.2) < 0.001
  defp canonical_score?(score) when is_integer(score), do: false

  defp canonical_score?(score) when is_binary(score) do
    case Float.parse(score) do
      {value, _} -> abs(value - 4.2) < 0.001
      :error -> false
    end
  end

  defp canonical_score?(_score), do: false

  defp stored_anomaly(series_key) do
    case Repo.query!(
           """
           SELECT events.message,
                  events.unmapped->>'event_id',
                  events.unmapped->'anomaly'->>'score',
                  CASE WHEN EXISTS (
                    SELECT 1 FROM platform.alert_pending_admissions AS pending
                    WHERE pending.event_id = events.id AND pending.event_time = events.time
                  ) THEN 'false' ELSE 'true' END
           FROM platform.ocsf_events AS events
           WHERE events.metadata->'service_radar'->>'series_key' = $1
           ORDER BY time ASC
           """,
           [series_key]
         ).rows do
      [[message, event_id, score, admitted]] ->
        assert canonical_score?(score)
        {message, event_id, admitted}

      other ->
        other
    end
  end

  defp stored_series_transitions(series_key) do
    Enum.map(
      Repo.query!(
        """
        SELECT events.message,
               CASE WHEN EXISTS (
                   SELECT 1 FROM platform.alert_pending_admissions AS pending
                   WHERE pending.event_id = events.id AND pending.event_time = events.time
                 ) THEN 'false' ELSE 'true' END
        FROM platform.ocsf_events AS events
        WHERE events.metadata->'service_radar'->>'series_key' = $1
        ORDER BY events.time ASC, events.created_at ASC, events.id ASC
        """,
        [series_key]
      ).rows,
      fn [message, admitted] -> {message, admitted} end
    )
  end

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
    id = uuid_string(row.id)

    Repo.query!(
      """
      DELETE FROM platform.alert_pending_admissions
      WHERE event_id = ($1::text)::uuid OR series_key = $1
      """,
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
      [id, row.time]
    )

    :ok
  end

  defp delete_episode_fixture!(series_key) do
    Repo.query!(
      "DELETE FROM platform.alert_pending_admissions WHERE series_key = $1",
      [series_key]
    )

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

  defp forecast_event_id(message) do
    case AnalyticsSignals.parse_message(message) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp capacity_forecast_message(series_key, event_id, message, time) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "prediction",
      "event_type" => "capacity_forecast",
      "class_uid" => 2004,
      "time" => time,
      "severity_id" => 3,
      "message" => message,
      "device_uid" => "sr:capacity-forecast-device",
      "capacity_forecast" => %{
        "resource_key" => series_key,
        "metric_name" => "disk.used_percent"
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

  defp pending_admission_messages(series_key) do
    Enum.map(
      Repo.query!(
        """
        SELECT occurrence->>'message'
        FROM platform.alert_pending_admissions
        WHERE series_key = $1
        ORDER BY seq ASC
        """,
        [series_key]
      ).rows,
      fn [message] -> message end
    )
  end

  defp pending_admission_ids(series_key) do
    Enum.map(
      Repo.query!(
        """
        SELECT occurrence->>'message', event_id::text
        FROM platform.alert_pending_admissions
        WHERE series_key = $1
        ORDER BY seq ASC
        """,
        [series_key]
      ).rows,
      fn [message, event_id] -> {message, event_id} end
    )
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

  defp stored_finding(row) do
    %{rows: [[status, activity_id, activity_name, admitted]]} =
      Repo.query!(
        """
        SELECT events.status, events.activity_id, events.activity_name,
               CASE WHEN EXISTS (
                    SELECT 1 FROM platform.alert_pending_admissions AS pending
                    WHERE pending.event_id = events.id AND pending.event_time = events.time
                  ) THEN 'false' ELSE 'true' END
        FROM platform.ocsf_events AS events
        WHERE events.id = ($1::text)::uuid AND events.time = $2
        """,
        [uuid_string(row.id), row.time]
      )

    {status, activity_id, activity_name, admitted}
  end

  defp pending_occurrence_count(row) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.alert_pending_admissions WHERE event_id = ($1::text)::uuid",
        [uuid_string(row.id)]
      )

    count
  end

  defp stored_metadata(row) do
    %{rows: [[metadata]]} =
      Repo.query!(
        "SELECT metadata FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    metadata || %{}
  end

  defp stored_finding_version(row) do
    %{rows: [[version]]} =
      Repo.query!(
        """
        SELECT unmapped->>'finding_version'
        FROM platform.ocsf_events
        WHERE id = ($1::text)::uuid AND time = $2
        """,
        [uuid_string(row.id), row.time]
      )

    version
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
