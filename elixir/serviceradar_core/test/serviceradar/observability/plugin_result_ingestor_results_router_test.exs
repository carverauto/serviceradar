defmodule ServiceRadar.Observability.PluginResultIngestorResultsRouterTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Observability.PluginResultAttemptPruneWorker
  alias ServiceRadar.Observability.PluginResultQuarantine

  defmodule BudgetIngestor do
    @moduledoc false

    def ingest(payload, status) do
      Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_fun).(
        payload,
        status
      )
    end
  end

  test "results router leaves plugin result state ownership with the plugin ingestor" do
    previous_ingestor =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor)

    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor,
      PluginResultIngestor
    )

    on_exit(fn -> restore_env(:plugin_result_ingestor, previous_ingestor) end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    enclosing_timestamp = DateTime.shift(observed_at, second: 10)
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: enclosing_timestamp,
        message: Jason.encode!(payload)
      })

    assert :ok = ServiceRadar.Ingestion.ResultIngestor.process_and_publish(routed_status)

    assert [[reported_at, true, "edge plugin completed", _details] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    succeeded_at = marker_timestamp(reported_at, 1, "succeeded")

    assert [[true, "edge plugin completed", ^succeeded_at]] =
             current_state_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "observation_timestamp" => observation_timestamp,
               "status" => "succeeded"
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert observation_timestamp == DateTime.to_iso8601(observed_at)
    refute succeeded_at == enclosing_timestamp

    assert_receive {:service_status_updated,
                    %ServiceStatus{
                      agent_id: agent_id,
                      gateway_id: gateway_id,
                      timestamp: ^reported_at
                    }}

    assert agent_id == status.agent_id
    assert gateway_id == status.gateway_id
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  test "retained supervised delivery keeps plugin history and state under the plugin ingestor" do
    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
    Application.put_env(:serviceradar_core, :results_router_batching, true)

    on_exit(fn ->
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:results_router_batching, previous_batching)
    end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: DateTime.shift(observed_at, second: 15),
        message: Jason.encode!(payload)
      })

    ServiceRadar.TestSupport.start_ingestion_topology!()
    routed_status = Map.put(routed_status, :delivery_capabilities, ["plugin-result-retained:v1"])
    assert [] = history_rows(status)

    assert :ok =
             GenServer.call(ServiceRadar.StatusHandler, {:status_update, routed_status}, 5_000)

    assert [[reported_at, true, "edge plugin completed", _] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    succeeded_at = marker_timestamp(reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^reported_at}}
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  describe "retained delivery that exceeds the worker budget" do
    setup do
      previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
      previous_fun = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_fun)

      previous_max =
        Application.get_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts)

      # The killed worker must not hold the shared sandbox connection, so the
      # over-budget handler sleeps outside any transaction.
      Application.put_env(:serviceradar_core, :plugin_result_ingestor, BudgetIngestor)

      on_exit(fn ->
        restore_env(:plugin_result_ingestor, previous_ingestor)
        restore_env(:plugin_result_ingestor_test_fun, previous_fun)
        restore_env(:plugin_result_quarantine_max_timeouts, previous_max)
      end)

      %{lane: start_retained_lane!()}
    end

    test "an execution timeout commits an attempt row that a later success clears", %{lane: lane} do
      test_pid = self()
      calls = :counters.new(1, [])

      put_ingest_fun(fn payload, _status ->
        :counters.add(calls, 1, 1)
        send(test_pid, {:ingest, payload["summary"]})
        if :counters.get(calls, 1) == 1, do: Process.sleep(30_000)
        :ok
      end)

      status = retained_status("over-budget-once")

      assert {:error, :execution_timeout} = admit_and_await(lane, status)
      assert_receive {:ingest, "over-budget-once"}
      assert [[1, 1, "active", "execution_timeout"]] = attempt_rows(status.agent_id)

      assert :ok = admit_and_await(lane, status)
      assert_receive {:ingest, "over-budget-once"}
      assert [] = attempt_rows(status.agent_id)
    end

    test "a result that keeps exceeding its budget is quarantined, acknowledged and retryable",
         %{lane: lane} do
      test_pid = self()
      Application.put_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts, 2)

      put_ingest_fun(fn payload, _status ->
        send(test_pid, {:ingest, payload["summary"]})
        if payload["summary"] == "always-over-budget", do: Process.sleep(30_000)
        :ok
      end)

      over_budget = retained_status("always-over-budget")
      later = retained_status("within-budget", over_budget.agent_id)

      for attempt <- 1..2 do
        assert {:error, :execution_timeout} = admit_and_await(lane, over_budget)
        assert_receive {:ingest, "always-over-budget"}

        expected_state = if attempt == 2, do: "quarantined", else: "active"

        assert [[^attempt, ^attempt, ^expected_state, "execution_timeout"]] =
                 attempt_rows(over_budget.agent_id)
      end

      assert [%{state: "quarantined", payload_bytes: payload_bytes, result_key: result_key}] =
               PluginResultQuarantine.list_quarantined(agent_id: over_budget.agent_id)

      assert payload_bytes == byte_size(over_budget.message)

      # The redelivery is acknowledged without running the handlers again, so
      # the agent's retained queue drains and its later results are ingested.
      assert :ok = admit_and_await(lane, over_budget)
      refute_receive {:ingest, "always-over-budget"}, 200

      assert :ok = admit_and_await(lane, later)
      assert_receive {:ingest, "within-budget"}

      assert [[2, 2, "quarantined", "execution_timeout"]] =
               attempt_rows(over_budget.agent_id)

      # A retryable persistence error must leave the only retained copy
      # quarantined, so a second retry still finds it.
      put_ingest_fun(fn payload, _status ->
        send(test_pid, {:ingest, payload["summary"]})
        {:error, :persistence_failed}
      end)

      assert {:error, :persistence_failed} =
               PluginResultQuarantine.retry_quarantined(over_budget.agent_id, result_key)

      assert_receive {:ingest, "always-over-budget"}

      assert [[2, 2, "quarantined", "execution_timeout"]] =
               attempt_rows(over_budget.agent_id)

      assert [%{state: "quarantined", result_key: ^result_key}] =
               PluginResultQuarantine.list_quarantined(agent_id: over_budget.agent_id)

      put_ingest_fun(fn payload, _status ->
        send(test_pid, {:ingest, payload["summary"]})
        :ok
      end)

      assert :ok = PluginResultQuarantine.retry_quarantined(over_budget.agent_id, result_key)
      assert_receive {:ingest, "always-over-budget"}
      assert [] = attempt_rows(over_budget.agent_id)
    end
  end

  describe "attempt row retention prune (#6061)" do
    setup do
      previous_active =
        Application.get_env(:serviceradar_core, :plugin_result_attempt_active_retention_days)

      previous_quarantine =
        Application.get_env(:serviceradar_core, :plugin_result_quarantine_retention_days)

      previous_batch_size =
        Application.get_env(:serviceradar_core, :plugin_result_attempt_prune_batch_size)

      on_exit(fn ->
        restore_env(:plugin_result_attempt_active_retention_days, previous_active)
        restore_env(:plugin_result_quarantine_retention_days, previous_quarantine)
        restore_env(:plugin_result_attempt_prune_batch_size, previous_batch_size)
      end)

      :ok
    end

    test "prunes expired active and quarantined attempt rows while keeping recent ones" do
      suffix = System.unique_integer([:positive])
      agent_id = "prune-agent-#{suffix}"
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      on_exit(fn ->
        Repo.query!(
          "DELETE FROM platform.plugin_result_ingestion_attempts WHERE agent_id = $1",
          [agent_id]
        )
      end)

      insert_attempt_row!(agent_id, "active-expired-#{suffix}", "active",
        last_attempt_at: DateTime.shift(now, day: -8)
      )

      insert_attempt_row!(agent_id, "active-recent-#{suffix}", "active",
        last_attempt_at: DateTime.shift(now, day: -2)
      )

      insert_attempt_row!(agent_id, "quarantined-mid-#{suffix}", "quarantined",
        quarantined_at: DateTime.shift(now, week: -2),
        last_attempt_at: DateTime.shift(now, week: -2)
      )

      insert_attempt_row!(agent_id, "quarantined-expired-#{suffix}", "quarantined",
        quarantined_at: DateTime.shift(now, day: -31),
        last_attempt_at: DateTime.shift(now, day: -31)
      )

      insert_attempt_row!(agent_id, "quarantined-null-ts-expired-#{suffix}", "quarantined",
        quarantined_at: nil,
        last_attempt_at: DateTime.shift(now, week: -5)
      )

      assert :ok = PluginResultAttemptPruneWorker.perform(%Oban.Job{args: %{}})

      remaining_keys =
        List.flatten(
          Repo.query!(
            """
            SELECT result_key
            FROM platform.plugin_result_ingestion_attempts
            WHERE agent_id = $1
            ORDER BY result_key
            """,
            [agent_id]
          ).rows
        )

      assert remaining_keys == [
               "active-recent-#{suffix}",
               "quarantined-mid-#{suffix}"
             ]

      # Tightening the quarantine window via application env prunes the 14-day-old row too.
      Application.put_env(:serviceradar_core, :plugin_result_quarantine_retention_days, 10)
      assert :ok = PluginResultAttemptPruneWorker.perform(%Oban.Job{args: %{}})

      remaining_after_override =
        List.flatten(
          Repo.query!(
            """
            SELECT result_key
            FROM platform.plugin_result_ingestion_attempts
            WHERE agent_id = $1
            ORDER BY result_key
            """,
            [agent_id]
          ).rows
        )

      assert remaining_after_override == ["active-recent-#{suffix}"]
    end

    test "deletes expired attempt rows in primary-key batches and records attempt_pruned metric" do
      if !Process.whereis(RuntimeMetrics) do
        start_supervised!(
          {RuntimeMetrics, interval_ms: 60_000, publish_opts: [request: fn _, _, _ -> :ok end]}
        )
      end

      suffix = System.unique_integer([:positive])
      agent_id = "prune-batch-agent-#{suffix}"
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      on_exit(fn ->
        Repo.query!(
          "DELETE FROM platform.plugin_result_ingestion_attempts WHERE agent_id = $1",
          [agent_id]
        )
      end)

      for idx <- 1..3 do
        insert_attempt_row!(agent_id, "expired-active-#{idx}-#{suffix}", "active",
          last_attempt_at: DateTime.shift(now, day: -10)
        )
      end

      for idx <- 1..2 do
        insert_attempt_row!(agent_id, "expired-quarantined-#{idx}-#{suffix}", "quarantined",
          quarantined_at: DateTime.shift(now, day: -40),
          last_attempt_at: DateTime.shift(now, day: -40)
        )
      end

      insert_attempt_row!(agent_id, "fresh-active-#{suffix}", "active",
        last_attempt_at: DateTime.shift(now, day: -1)
      )

      before_pruned = pruned_metric_counter()

      assert {:ok, %{deleted: deleted, batches: batches}} =
               PluginResultQuarantine.prune(now: now, batch_size: 2)

      assert deleted >= 5
      assert batches >= 3
      assert pruned_metric_counter() - before_pruned == deleted

      remaining =
        List.flatten(
          Repo.query!(
            """
            SELECT result_key
            FROM platform.plugin_result_ingestion_attempts
            WHERE agent_id = $1
            """,
            [agent_id]
          ).rows
        )

      assert remaining == ["fresh-active-#{suffix}"]
    end
  end

  defp insert_attempt_row!(agent_id, result_key, state, opts) do
    last_attempt_at = Keyword.fetch!(opts, :last_attempt_at)
    quarantined_at = Keyword.get(opts, :quarantined_at)
    reason = if state == "quarantined", do: "execution_timeout_budget_exceeded"

    Repo.query!(
      """
      INSERT INTO platform.plugin_result_ingestion_attempts (
        agent_id, result_key, gateway_id, partition, service_type, service_name,
        observation_timestamp, payload_digest, payload_bytes, attempt_count,
        consecutive_timeout_count, state, last_outcome, last_error,
        quarantine_reason, quarantined_at, last_attempt_at, retained_status,
        inserted_at, updated_at
      )
      VALUES (
        $1, $2, 'prune-gateway', 'default', 'plugin', 'prune-service',
        $6, 'digest', 64, 3,
        3, $3, 'execution_timeout', 'worker_execution_timeout',
        $4, $5, $6, '{}'::jsonb,
        $6, $6
      )
      """,
      [agent_id, result_key, state, reason, quarantined_at, last_attempt_at]
    )
  end

  defp pruned_metric_counter do
    case :ets.lookup(RuntimeMetrics, {:events, :retained_plugin_result, :attempt_pruned}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  defp put_ingest_fun(fun),
    do: Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_fun, fun)

  defp retained_status(summary, agent_id \\ nil) do
    suffix = System.unique_integer([:positive])

    %{
      source: "plugin-result",
      service_type: "plugin",
      service_name: "budget-plugin-#{suffix}",
      partition: "default",
      agent_id: agent_id || "budget-agent-#{suffix}",
      gateway_id: "budget-gateway-#{suffix}",
      available: true,
      agent_timestamp: System.os_time(:second),
      message:
        Jason.encode!(%{
          "status" => "OK",
          "summary" => summary,
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }),
      delivery_capabilities: ["plugin-result-retained:v1"]
    }
  end

  defp attempt_rows(agent_id) do
    Repo.query!(
      """
      SELECT attempt_count, consecutive_timeout_count, state, last_outcome
      FROM platform.plugin_result_ingestion_attempts
      WHERE agent_id = $1
      """,
      [agent_id]
    ).rows
  end

  defp admit_and_await(lane, status) do
    reply_ref = make_ref()
    assert :ok = Lane.admit(lane, status, {self(), reply_ref})
    assert_receive {^reply_ref, result}, 5_000
    result
  end

  defp start_retained_lane! do
    suffix = System.unique_integer([:positive])
    task_sup = start_supervised!({Task.Supervisor, name: :"retained_task_#{suffix}"}, id: :task)

    lease_sup =
      start_supervised!({Task.Supervisor, name: :"retained_lease_#{suffix}"}, id: :lease)

    start_supervised!(
      {RetainedPluginLane,
       name: :"retained_lane_#{suffix}",
       task_supervisor: task_sup,
       lease_supervisor: lease_sup,
       config: [
         max_items: 8,
         max_bytes: 1_024 * 1_024,
         max_items_per_agent: 4,
         queue_wait_ms: 500,
         worker_timeout_ms: 1_000,
         gateway_call_timeout_ms: 15_000
       ]},
      id: :lane
    )
  end
end
