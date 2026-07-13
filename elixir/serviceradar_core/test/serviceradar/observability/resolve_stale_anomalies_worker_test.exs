defmodule ServiceRadar.Observability.ResolveStaleAnomaliesWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.ResolveStaleAnomaliesWorker

  defmodule RepoStub do
    @moduledoc false

    def query(sql, params) do
      send(Process.get(:resolve_stale_test_pid), {:episode_query, sql, params})
      Process.get(:resolve_stale_repo_reply) || {:ok, %{rows: []}}
    end
  end

  defmodule RaisingRepoStub do
    @moduledoc false

    def query(_sql, _params), do: raise("episode lookup exploded")
  end

  @config_keys [
    :stale_anomaly_resolve_hours,
    :stale_anomaly_episode_freshness_hours,
    :stale_anomaly_episode_liveness_check
  ]

  setup do
    previous = Enum.map(@config_keys, &{&1, Application.get_env(:serviceradar_core, &1)})
    Enum.each(@config_keys, &Application.delete_env(:serviceradar_core, &1))

    Process.put(:resolve_stale_test_pid, self())

    on_exit(fn ->
      Process.delete(:resolve_stale_test_pid)
      Process.delete(:resolve_stale_repo_reply)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)
  end

  test "live_episode_series_keys selects open episodes fresher than the window" do
    Process.put(
      :resolve_stale_repo_reply,
      {:ok, %{rows: [["series-a"], ["series-b"], [nil]]}}
    )

    now = ~U[2026-07-12 12:00:00.000000Z]

    assert ResolveStaleAnomaliesWorker.live_episode_series_keys(now, RepoStub) ==
             MapSet.new(["series-a", "series-b"])

    # Default freshness window mirrors the 6h stale window.
    expected_cutoff = ~N[2026-07-12 06:00:00.000000]
    assert_receive {:episode_query, sql, [^expected_cutoff]}
    assert sql =~ "status = 'open'"
    assert sql =~ "last_seen_at >="
  end

  test "lookup error fails open (empty set) with a warning" do
    Process.put(:resolve_stale_repo_reply, {:error, :boom})

    log =
      capture_log(fn ->
        assert ResolveStaleAnomaliesWorker.live_episode_series_keys(
                 DateTime.utc_now(),
                 RepoStub
               ) == MapSet.new()
      end)

    assert log =~ "episode liveness lookup failed"
  end

  test "lookup raise fails open (empty set) with a warning" do
    log =
      capture_log(fn ->
        assert ResolveStaleAnomaliesWorker.live_episode_series_keys(
                 DateTime.utc_now(),
                 RaisingRepoStub
               ) == MapSet.new()
      end)

    assert log =~ "episode liveness lookup failed"
  end

  test "episode liveness check can be disabled" do
    Application.put_env(:serviceradar_core, :stale_anomaly_episode_liveness_check, false)

    assert ResolveStaleAnomaliesWorker.live_episode_series_keys(DateTime.utc_now(), RepoStub) ==
             MapSet.new()

    refute_receive {:episode_query, _sql, _params}
  end

  test "episode freshness window defaults to the stale window and can be configured" do
    assert ResolveStaleAnomaliesWorker.episode_freshness_hours() == 6

    Application.put_env(:serviceradar_core, :stale_anomaly_resolve_hours, 12)
    assert ResolveStaleAnomaliesWorker.episode_freshness_hours() == 12

    Application.put_env(:serviceradar_core, :stale_anomaly_episode_freshness_hours, 2)
    assert ResolveStaleAnomaliesWorker.episode_freshness_hours() == 2
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
