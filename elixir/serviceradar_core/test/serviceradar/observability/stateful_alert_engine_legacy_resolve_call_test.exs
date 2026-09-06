defmodule ServiceRadar.Observability.StatefulAlertEngineLegacyResolveCallTest do
  @moduledoc """
  DB-free tests for the rolling-deploy compat clause of the stale-anomaly sweep.

  Shards are Horde-placed cluster-wide, so during a rolling deploy a worker on
  a pre-live-set node fans out the legacy 3-tuple
  `{:resolve_stale_anomalies, {rule, cutoff, now}}` to shards running this
  code. These tests pin down the compat contract: the legacy message is
  handled (no FunctionClauseError, shard stays alive) and resolves exactly
  like a 4-tuple call with an empty live-set.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEngine

  setup do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, :repo_enabled)
        value -> Application.put_env(:serviceradar_core, :repo_enabled, value)
      end
    end)

    # Start the shard directly (no Horde placement) so the test exercises only
    # the handle_call message contract.
    {:ok, pid} = GenServer.start(StatefulAlertEngine, %{shard: 5})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, pid: pid}
  end

  test "legacy 3-tuple resolve message behaves like an empty live-set call", %{pid: pid} do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -6 * 3600, :second)

    capture_log(fn ->
      legacy_reply =
        GenServer.call(pid, {:resolve_stale_anomalies, {"some-rule", cutoff, now}})

      empty_live_set_reply =
        GenServer.call(
          pid,
          {:resolve_stale_anomalies, {"some-rule", cutoff, now, MapSet.new()}}
        )

      assert legacy_reply == {:error, :repo_unavailable}
      assert legacy_reply == empty_live_set_reply
    end)

    # The compat clause must not crash the shard the way an unmatched
    # handle_call would (FunctionClauseError → Horde restart).
    assert Process.alive?(pid)
  end
end
