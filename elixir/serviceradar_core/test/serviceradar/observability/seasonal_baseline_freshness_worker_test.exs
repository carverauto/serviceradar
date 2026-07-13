defmodule ServiceRadar.Observability.SeasonalBaselineFreshnessWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.SeasonalBaselineFreshnessWorker

  setup do
    previous = Application.get_env(:serviceradar_core, :seasonal_baseline_freshness_hours)

    on_exit(fn ->
      case previous do
        nil ->
          Application.delete_env(:serviceradar_core, :seasonal_baseline_freshness_hours)

        value ->
          Application.put_env(:serviceradar_core, :seasonal_baseline_freshness_hours, value)
      end
    end)
  end

  defp health_recorder(pid) do
    fn check, healthy?, metadata ->
      send(pid, {:health, check, healthy?, metadata})
      :ok
    end
  end

  defp heartbeat_loader(pid, result) do
    fn hours ->
      send(pid, {:heartbeats_loaded, hours})
      result
    end
  end

  defp profile do
    %{id: Ecto.UUID.generate(), params: %{"seasonal_baselines" => %{}}}
  end

  defp run(profiles_result, heartbeats_result, opts \\ []) do
    SeasonalBaselineFreshnessWorker.run(
      Keyword.merge(
        [
          actor: :test_actor,
          profiles_loader: fn _actor -> profiles_result end,
          heartbeat_loader: heartbeat_loader(self(), heartbeats_result),
          health_recorder: health_recorder(self())
        ],
        opts
      )
    )
  end

  test "records healthy when the producer heartbeat landed inside the window" do
    heartbeats = [%{new_state: :healthy, reason: :heartbeat}]

    assert :ok = run({:ok, [profile()]}, {:ok, heartbeats})
    assert_received {:heartbeats_loaded, 26}
    assert_received {:health, "seasonal-baseline-freshness", true, %{}}
  end

  test "fires unhealthy when no heartbeat landed inside the freshness window" do
    log =
      capture_log(fn ->
        assert :ok = run({:ok, [profile()]}, {:ok, []})
      end)

    assert log =~ "delivery heartbeat within 26h"
    assert_received {:health, "seasonal-baseline-freshness", false, %{"freshness_hours" => 26}}
  end

  test "non-healthy events inside the window do not count as a heartbeat" do
    heartbeats = [%{new_state: :unhealthy, reason: :health_check_failed}]

    capture_log(fn ->
      assert :ok = run({:ok, [profile()]}, {:ok, heartbeats})
    end)

    assert_received {:health, "seasonal-baseline-freshness", false, _metadata}
  end

  test "skips silently when there are no enabled anomaly profiles" do
    assert :ok = run({:ok, []}, {:ok, []})
    refute_received {:heartbeats_loaded, _hours}
    refute_received {:health, _check, _healthy?, _metadata}
  end

  test "profile load failures fail open: log, no verdict, no crash" do
    log =
      capture_log(fn ->
        assert :ok = run({:error, :database_unavailable}, {:ok, []})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}

    log =
      capture_log(fn ->
        assert :ok =
                 run(nil, {:ok, []}, profiles_loader: fn _actor -> raise "loader boom" end)
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}
  end

  test "heartbeat load failures fail open: log, no verdict, no crash" do
    log =
      capture_log(fn ->
        assert :ok = run({:ok, [profile()]}, {:error, :database_unavailable})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}
  end

  test "honors the configured freshness window" do
    Application.put_env(:serviceradar_core, :seasonal_baseline_freshness_hours, 2)

    capture_log(fn ->
      assert :ok = run({:ok, [profile()]}, {:ok, []})
    end)

    assert_received {:heartbeats_loaded, 2}
    assert_received {:health, "seasonal-baseline-freshness", false, %{"freshness_hours" => 2}}
  end

  describe "healthy_heartbeat?/1" do
    test "accepts only healthy events" do
      assert SeasonalBaselineFreshnessWorker.healthy_heartbeat?(%{new_state: :healthy})
      refute SeasonalBaselineFreshnessWorker.healthy_heartbeat?(%{new_state: :unhealthy})
      refute SeasonalBaselineFreshnessWorker.healthy_heartbeat?(%{new_state: :degraded})
      refute SeasonalBaselineFreshnessWorker.healthy_heartbeat?(%{})
    end
  end
end
