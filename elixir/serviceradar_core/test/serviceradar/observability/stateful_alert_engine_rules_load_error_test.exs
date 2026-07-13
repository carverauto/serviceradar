defmodule ServiceRadar.Observability.StatefulAlertEngineRulesLoadErrorTest do
  @moduledoc """
  DB-free tests for the rule-load ERROR contract: a returned query error
  (e.g. schema drift when code selects a column an unapplied migration adds)
  must not be mistaken for "zero rules". The shard keeps its previously
  loaded rules, logs once until recovery, emits telemetry, and retries.

  Regression: `Ash.read` errors were silently converted to `[]` by
  `unwrap_page(_)` and `rules_loaded_at` was stamped, so every shard quietly
  evaluated against zero rules with no log line (observed live on demo when
  v1.4.14 ran against a pre-migration schema).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEngine

  @rules_load_failed_event [:serviceradar, :stateful_alert_engine, :rules_load_failed]
  @rules_loaded_event [:serviceradar, :stateful_alert_engine, :rules_loaded]

  setup do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)

    handler_id = {__MODULE__, self()}
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [@rules_load_failed_event, @rules_loaded_event],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    {:ok, mode} = Agent.start_link(fn -> {:ok, []} end)

    reader = fn -> Agent.get(mode, & &1) end

    # Start with the repo flagged unavailable so init's snapshot load takes the
    # repo-less branch (no real Repo runs in this suite), then flip to
    # available with a stand-in registered process so load_rules reaches the
    # injected reader.
    Application.put_env(:serviceradar_core, :repo_enabled, false)
    {:ok, pid} = GenServer.start(StatefulAlertEngine, %{shard: 3, rules_reader: reader})

    fake_repo =
      if is_nil(Process.whereis(ServiceRadar.Repo)) do
        {:ok, agent} = Agent.start(fn -> :fake_repo end, name: ServiceRadar.Repo)
        agent
      end

    Application.put_env(:serviceradar_core, :repo_enabled, true)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      if Process.alive?(pid), do: GenServer.stop(pid)
      if is_pid(fake_repo) and Process.alive?(fake_repo), do: Agent.stop(fake_repo)

      case previous do
        nil -> Application.delete_env(:serviceradar_core, :repo_enabled)
        value -> Application.put_env(:serviceradar_core, :repo_enabled, value)
      end
    end)

    {:ok, pid: pid, mode: mode}
  end

  test "query errors keep previous rules, log once, emit telemetry, and recover", %{
    pid: pid,
    mode: mode
  } do
    rule = %{id: rule_id_for_shard(3)}
    Agent.update(mode, fn _ -> {:ok, [rule]} end)

    capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)
    assert_receive {:telemetry, @rules_loaded_event, %{count: 1}, %{shard: 3}}
    assert length(:sys.get_state(pid).rules) == 1

    Agent.update(mode, fn _ -> {:error, :undefined_column} end)
    expire_rules_cache(pid)

    first_log =
      capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)

    assert first_log =~ "failed to load alert rules"
    assert first_log =~ "keeping 1 previously loaded rules"
    assert_receive {:telemetry, @rules_load_failed_event, %{count: 1}, %{shard: 3}}
    assert length(:sys.get_state(pid).rules) == 1

    second_log =
      capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)

    refute second_log =~ "failed to load alert rules"
    assert_receive {:telemetry, @rules_load_failed_event, %{count: 1}, %{shard: 3}}

    Agent.update(mode, fn _ -> {:ok, [rule]} end)

    recovery_log =
      capture_log(fn -> assert :ok = GenServer.call(pid, {:evaluate_events, []}) end)

    assert recovery_log =~ "recovered"
    assert_receive {:telemetry, @rules_loaded_event, %{count: 1}, %{shard: 3}}
    refute :sys.get_state(pid).rules_load_error_logged
  end

  # A failed load leaves rules_loaded_at unstamped so recovery is retried on
  # the next evaluation; a prior successful load stamps it, so age it out to
  # force the reload path.
  defp expire_rules_cache(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | rules_loaded_at: System.monotonic_time(:millisecond) - 120_000}
    end)
  end

  defp rule_id_for_shard(shard) do
    (&Ash.UUID.generate/0)
    |> Stream.repeatedly()
    |> Enum.find(fn id -> :erlang.phash2(id, 8) == shard end)
  end
end
