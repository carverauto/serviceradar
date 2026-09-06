defmodule ServiceRadar.Observability.StatefulAlertEngineRepoUnavailableTest do
  @moduledoc """
  DB-free tests for shard behavior on repo-less nodes (gateway/web tiers).

  A shard placed on a node without the core Repo loads zero rules, which
  silently drops every alert evaluation. These tests pin down the loud-failure
  contract: a once-per-shard-process warning plus telemetry on every skipped
  load, so misplaced shards are visible on dashboards.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEngine

  @repo_unavailable_event [:serviceradar, :stateful_alert_engine, :repo_unavailable]
  @rules_loaded_event [:serviceradar, :stateful_alert_engine, :rules_loaded]

  setup do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    handler_id = {__MODULE__, self()}
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [@repo_unavailable_event, @rules_loaded_event],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case previous do
        nil -> Application.delete_env(:serviceradar_core, :repo_enabled)
        value -> Application.put_env(:serviceradar_core, :repo_enabled, value)
      end
    end)

    # Start the shard directly (no Horde placement) so the test exercises only
    # the load_rules contract.
    {:ok, pid} = GenServer.start(StatefulAlertEngine, %{shard: 3})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, pid: pid}
  end

  test "warns once per shard process and emits telemetry on every repo-less load", %{pid: pid} do
    first_log =
      capture_log(fn ->
        assert {:error, :repo_unavailable} = GenServer.call(pid, {:evaluate_events, []})
      end)

    assert first_log =~ "StatefulAlertEngine shard 3"
    assert first_log =~ "has no repo available"

    assert_receive {:telemetry, @repo_unavailable_event, %{count: 1}, %{shard: 3, node: node}}
    assert node == node()

    second_log =
      capture_log(fn ->
        assert {:error, :repo_unavailable} = GenServer.call(pid, {:evaluate_events, []})
      end)

    refute second_log =~ "has no repo available"

    assert_receive {:telemetry, @repo_unavailable_event, %{count: 1}, %{shard: 3}}
  end

  test "does not report rules as loaded when the repo is unavailable", %{pid: pid} do
    capture_log(fn ->
      assert {:error, :repo_unavailable} = GenServer.call(pid, {:evaluate_metrics, []})
    end)

    assert_receive {:telemetry, @repo_unavailable_event, %{count: 1}, %{shard: 3}}
    refute_receive {:telemetry, @rules_loaded_event, _measurements, _metadata}
  end
end
