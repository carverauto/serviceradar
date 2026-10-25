defmodule ServiceRadar.ResultsRouterAdmissionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Observability.PluginResultQuarantine
  alias ServiceRadar.ResultsRouter

  defmodule TestPluginIngestor do
    @moduledoc false

    def ingest(payload, status) do
      case Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_fun) do
        fun when is_function(fun, 2) ->
          fun.(payload, status)

        _ ->
          Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_result)
      end
    end
  end

  setup do
    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_result = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_result)
    previous_fun = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_fun)

    previous_max_timeouts =
      Application.get_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts)

    PluginResultQuarantine.clear_all!()
    Application.put_env(:serviceradar_core, :plugin_result_ingestor, TestPluginIngestor)

    on_exit(fn ->
      PluginResultQuarantine.clear_all!()
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:plugin_result_ingestor_test_result, previous_result)
      restore_env(:plugin_result_ingestor_test_fun, previous_fun)
      restore_env(:plugin_result_quarantine_max_timeouts, previous_max_timeouts)
    end)
  end

  test "acknowledges a durably recorded handler-domain failure" do
    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor_test_result,
      {:error, {:plugin_result_handlers_failed, [{TestPluginIngestor, "failed"}]}}
    )

    st = status()
    assert :ok = ResultsRouter.process_retained_plugin(st)

    attempt = PluginResultQuarantine.get_attempt_for_status(st)
    assert attempt.attempt_count == 1
    assert attempt.consecutive_timeout_count == 0
    assert attempt.last_outcome == "handler_error"
    assert attempt.state == "active"
  end

  test "preserves retryable persistence and artifact cleanup failures" do
    for error <- [
          {:error, {:plugin_result_status_persistence_failed, "database unavailable"}},
          {:error,
           {:plugin_result_artifact_cleanup_failed, [{TestPluginIngestor, "cleanup failed"}]}}
        ] do
      Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_result, error)
      assert ^error = ResultsRouter.process_retained_plugin(status())
    end
  end

  test "a synthetic result that always exceeds budget is attempted at most N times, quarantined, acknowledged on redelivery, and later results are ingested" do
    test_pid = self()
    max_timeouts = 2
    Application.put_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts, max_timeouts)

    handler_id = "quarantine-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :plugin_result, :quarantined],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_quarantined, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_fun, fn payload, _st ->
      send(test_pid, {:handler_attempted, payload["summary"]})

      if payload["summary"] == "always-exceeds-budget" do
        Process.sleep(250)
        :ok
      else
        :ok
      end
    end)

    lane = start_test_retained_lane!(worker_timeout_ms: 40)

    bad_status =
      status(%{
        agent_id: "agent-quarantine-1",
        service_name: "proxmox-enrichment",
        summary: "always-exceeds-budget",
        observed_at: "2026-10-25T05:00:00Z"
      })

    later_status =
      status(%{
        agent_id: "agent-quarantine-1",
        service_name: "proxmox-enrichment",
        summary: "subsequent-healthy-result",
        observed_at: "2026-10-25T05:01:00Z"
      })

    for attempt_num <- 1..max_timeouts do
      assert {:error, :execution_timeout} = admit_and_await(lane, bad_status)
      assert_receive {:handler_attempted, "always-exceeds-budget"}, 500

      recorded = PluginResultQuarantine.get_attempt_for_status(bad_status)
      assert recorded.attempt_count == attempt_num
      assert recorded.consecutive_timeout_count == attempt_num
      assert recorded.last_outcome == "execution_timeout"
    end

    quarantined = PluginResultQuarantine.get_attempt_for_status(bad_status)
    assert quarantined.state == "quarantined"
    assert quarantined.quarantine_reason == "execution_timeout_budget_exceeded"
    assert quarantined.payload_bytes == byte_size(bad_status.message)
    assert is_binary(quarantined.payload_digest) and byte_size(quarantined.payload_digest) == 64
    assert %DateTime{} = quarantined.quarantined_at

    assert_receive {:telemetry_quarantined, [:serviceradar, :plugin_result, :quarantined],
                    %{
                      count: 1,
                      attempt_count: ^max_timeouts,
                      consecutive_timeout_count: ^max_timeouts
                    },
                    %{agent_id: "agent-quarantine-1", reason: "execution_timeout_budget_exceeded"}}

    assert [listed] = PluginResultQuarantine.list_quarantined(agent_id: "agent-quarantine-1")
    assert listed.result_key == quarantined.result_key

    # Next redelivery is acknowledged so the agent queue drains without running handlers again.
    assert :ok = admit_and_await(lane, bad_status)
    refute_receive {:handler_attempted, "always-exceeds-budget"}, 60
    assert PluginResultQuarantine.get_attempt_for_status(bad_status).attempt_count == max_timeouts

    # Subsequent results from the same agent are ingested normally.
    assert :ok = admit_and_await(lane, later_status)
    assert_receive {:handler_attempted, "subsequent-healthy-result"}, 500
  end

  test "a result that times out once and then succeeds is ingested once and not quarantined" do
    test_pid = self()
    Application.put_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts, 3)
    counter = :counters.new(1, [:atomics])

    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_fun, fn payload, _st ->
      :counters.add(counter, 1, 1)
      run = :counters.get(counter, 1)
      send(test_pid, {:flaky_attempt, run, payload["summary"]})

      if run == 1 do
        Process.sleep(250)
        :ok
      else
        send(test_pid, {:ingested_once, payload["summary"]})
        :ok
      end
    end)

    lane = start_test_retained_lane!(worker_timeout_ms: 40)

    flaky_status =
      status(%{
        agent_id: "agent-flaky-1",
        service_name: "awx-discovery",
        summary: "times-out-once-then-succeeds",
        observed_at: "2026-10-25T05:02:00Z"
      })

    assert {:error, :execution_timeout} = admit_and_await(lane, flaky_status)
    assert_receive {:flaky_attempt, 1, "times-out-once-then-succeeds"}, 500

    first_record = PluginResultQuarantine.get_attempt_for_status(flaky_status)
    assert first_record.attempt_count == 1
    assert first_record.consecutive_timeout_count == 1
    assert first_record.state == "active"

    assert :ok = admit_and_await(lane, flaky_status)
    assert_receive {:flaky_attempt, 2, "times-out-once-then-succeeds"}, 500
    assert_receive {:ingested_once, "times-out-once-then-succeeds"}, 500

    final_record = PluginResultQuarantine.get_attempt_for_status(flaky_status)
    assert final_record.attempt_count == 2
    assert final_record.consecutive_timeout_count == 0
    assert final_record.state == "succeeded"
    assert final_record.last_outcome == "succeeded"
    assert final_record.quarantine_reason == nil
    assert [] == PluginResultQuarantine.list_quarantined(agent_id: "agent-flaky-1")
  end

  test "operator can retry a quarantined result" do
    test_pid = self()
    Application.put_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts, 2)
    allow_success = :atomics.new(1, [])
    :atomics.put(allow_success, 1, 0)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor_test_fun, fn payload, _st ->
      if :atomics.get(allow_success, 1) == 1 do
        send(test_pid, {:retried_and_ingested, payload["summary"]})
        :ok
      else
        Process.sleep(250)
        :ok
      end
    end)

    lane = start_test_retained_lane!(worker_timeout_ms: 40)

    retry_status =
      status(%{
        agent_id: "agent-operator-retry",
        service_name: "netbox-discovery",
        summary: "operator-retry-target",
        observed_at: "2026-10-25T05:03:00Z"
      })

    assert {:error, :execution_timeout} = admit_and_await(lane, retry_status)
    assert {:error, :execution_timeout} = admit_and_await(lane, retry_status)

    [quarantined] = PluginResultQuarantine.list_quarantined(agent_id: "agent-operator-retry")
    assert quarantined.state == "quarantined"

    :atomics.put(allow_success, 1, 1)

    assert {:ok, retried} =
             PluginResultQuarantine.retry_quarantined(
               quarantined.agent_id,
               quarantined.result_key
             )

    assert_receive {:retried_and_ingested, "operator-retry-target"}, 500
    assert retried.state == "succeeded"
    assert retried.consecutive_timeout_count == 0
    assert retried.quarantine_reason == nil
    assert [] == PluginResultQuarantine.list_quarantined(agent_id: "agent-operator-retry")
  end

  defp admit_and_await(lane, st) do
    reply_ref = make_ref()
    assert :ok = Lane.admit(lane, st, {self(), reply_ref})
    assert_receive {^reply_ref, result}, 1_000
    result
  end

  defp start_test_retained_lane!(overrides) do
    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"test_retained_task_sup_#{System.unique_integer([:positive])}"},
        id: {:task_sup, System.unique_integer([:positive])}
      )

    lease_sup =
      start_supervised!(
        {Task.Supervisor, name: :"test_retained_lease_sup_#{System.unique_integer([:positive])}"},
        id: {:lease_sup, System.unique_integer([:positive])}
      )

    lane_name = :"test_retained_plugin_lane_#{System.unique_integer([:positive])}"

    config =
      Keyword.merge(
        [
          max_items: 8,
          max_bytes: 1_024 * 1_024,
          max_items_per_agent: 4,
          queue_wait_ms: 200,
          worker_timeout_ms: 50,
          gateway_call_timeout_ms: 15_000
        ],
        overrides
      )

    start_supervised!(
      {RetainedPluginLane,
       name: lane_name, task_supervisor: task_sup, lease_supervisor: lease_sup, config: config},
      id: {:lane, lane_name}
    )
  end

  defp status(overrides \\ %{}) do
    summary = Map.get(overrides, :summary, "plugin ok")
    observed_at = Map.get(overrides, :observed_at, "2026-10-25T05:00:00Z")

    %{
      source: "plugin-result",
      service_type: "plugin",
      service_name: Map.get(overrides, :service_name, "plugin-svc"),
      partition: Map.get(overrides, :partition, "default"),
      gateway_id: Map.get(overrides, :gateway_id, "gateway-1"),
      message:
        Jason.encode!(%{
          "status" => "OK",
          "summary" => summary,
          "observed_at" => observed_at
        }),
      agent_id: Map.get(overrides, :agent_id, "agent-1")
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
