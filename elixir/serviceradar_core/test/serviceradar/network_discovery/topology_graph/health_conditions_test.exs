defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditionsTest do
  # async: false — these tests assert log LEVELS (error transition vs. info
  # repeats), so they temporarily raise the global Logger level above the test
  # env's :warning default. Sync modules run serially after the async suite, so
  # the level change cannot leak into concurrent tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  # Each test uses a unique condition key so async modules can never collide on
  # the shared :persistent_term namespace.
  defp unique_condition(context_tag) do
    condition = {:health_conditions_test, context_tag, System.unique_integer([:positive])}
    on_exit(fn -> HealthConditions.clear(condition) end)
    condition
  end

  test "report_failure/3 logs the transition at error level and repeats at info with the ongoing flag" do
    condition = unique_condition(:failure_dedup)
    message = "health-conditions-test failure #{System.unique_integer([:positive])}"

    refute HealthConditions.unhealthy?(condition)

    first =
      capture_log(fn ->
        assert :new_failure = HealthConditions.report_failure(condition, message, [])
      end)

    assert first =~ "[error] #{message}"
    assert HealthConditions.unhealthy?(condition)

    second =
      capture_log(fn ->
        assert :ongoing_failure = HealthConditions.report_failure(condition, message, [])
      end)

    assert second =~ "[info] #{message} (ongoing failure)"
    refute second =~ "[error] #{message}"
    assert %{occurrences: 2, since: %DateTime{}} = HealthConditions.get(condition)
  end

  test "report_recovery/3 logs the all-clear once and is a silent no-op when already healthy" do
    condition = unique_condition(:recovery)
    all_clear = "health-conditions-test all clear #{System.unique_integer([:positive])}"

    capture_log(fn ->
      assert :new_failure = HealthConditions.report_failure(condition, "boom", [])
    end)

    recovered =
      capture_log(fn ->
        assert :recovered = HealthConditions.report_recovery(condition, all_clear, [])
      end)

    assert recovered =~ "[info] #{all_clear}"
    refute HealthConditions.unhealthy?(condition)

    silent =
      capture_log(fn ->
        assert :already_healthy = HealthConditions.report_recovery(condition, all_clear, [])
      end)

    refute silent =~ all_clear
  end

  test "mark_unhealthy/2 preserves the original transition time across repeats" do
    condition = unique_condition(:since)

    {:new_failure, first_state} = HealthConditions.mark_unhealthy(condition, %{n: 1})
    {:ongoing_failure, second_state} = HealthConditions.mark_unhealthy(condition, %{n: 2})

    assert second_state.since == first_state.since
    assert second_state.occurrences == 2
    assert second_state.details == %{n: 2}

    assert {:recovered, %{occurrences: 2}} = HealthConditions.mark_healthy(condition)
    assert :already_healthy = HealthConditions.mark_healthy(condition)
  end
end
