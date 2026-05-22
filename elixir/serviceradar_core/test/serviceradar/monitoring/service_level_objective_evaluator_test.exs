defmodule ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluator

  @slo_id "019711bb-a8a5-7a55-bc96-9f3fc4fbeabc"
  @period_started_at ~U[2026-05-01 00:00:00Z]
  @period_ended_at ~U[2026-05-08 00:00:00Z]
  @evaluated_at ~U[2026-05-08 00:05:00Z]

  test "request-based SLO evaluation computes compliance, budget, and burn rate" do
    slo = %{
      id: @slo_id,
      slo_kind: :request_based,
      goal_basis_points: 8_500,
      alert_policy: %{"warn_budget_remaining_below_basis_points" => 2_500}
    }

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               period_started_at: @period_started_at,
               period_ended_at: @period_ended_at,
               evaluated_at: @evaluated_at,
               eligible_events: 60_480,
               good_events: 55_000
             })

    assert evaluation.compliance_basis_points == 9_093
    assert evaluation.error_budget_total == 9_072
    assert evaluation.error_budget_consumed == 5_480
    assert evaluation.error_budget_remaining == 3_592
    assert evaluation.budget_remaining_basis_points == 3_959
    assert evaluation.compliance_state == :compliant
    assert evaluation.severity == :info
    assert Decimal.eq?(evaluation.burn_rate_short, Decimal.new("0.604056"))
  end

  test "rolling compliance period is derived when explicit bounds are omitted" do
    slo = %{
      id: @slo_id,
      slo_kind: :request_based,
      goal_basis_points: 9_900,
      compliance_period_type: :rolling,
      rolling_period_days: 7
    }

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               evaluated_at: ~U[2026-05-21 13:15:30Z],
               eligible_events: 10_000,
               good_events: 9_950
             })

    assert evaluation.period_started_at == ~U[2026-05-14 13:15:30Z]
    assert evaluation.period_ended_at == ~U[2026-05-21 13:15:30Z]
    assert evaluation.compliance_state == :compliant
  end

  test "calendar compliance period is derived from calendar boundaries" do
    slo = %{
      id: @slo_id,
      slo_kind: :window_based,
      goal_basis_points: 9_900,
      compliance_period_type: :calendar,
      calendar_period: :week
    }

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               evaluated_at: ~U[2026-05-21 13:15:30Z],
               total_windows: 1_008,
               good_windows: 1_000
             })

    assert evaluation.period_started_at == ~U[2026-05-18 00:00:00Z]
    assert evaluation.period_ended_at == ~U[2026-05-25 00:00:00Z]
    assert evaluation.compliance_basis_points == 9_920
  end

  test "projected exhaustion is calculated from observed budget consumption rate" do
    slo = %{
      id: @slo_id,
      slo_kind: :request_based,
      goal_basis_points: 9_000,
      compliance_period_type: :rolling,
      rolling_period_days: 1
    }

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               evaluated_at: ~U[2026-05-21 12:00:00Z],
               eligible_events: 1_000,
               good_events: 950
             })

    assert evaluation.error_budget_total == 100
    assert evaluation.error_budget_consumed == 50
    assert evaluation.error_budget_remaining == 50
    assert evaluation.projected_exhaustion_at == ~U[2026-05-22 12:00:00Z]
  end

  test "request-based SLO evaluation marks budget exhaustion noncompliant" do
    slo = %{id: @slo_id, slo_kind: :request_based, goal_basis_points: 9_990}

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               period_started_at: @period_started_at,
               period_ended_at: @period_ended_at,
               evaluated_at: @evaluated_at,
               eligible_events: 10_000,
               good_events: 9_985
             })

    assert evaluation.compliance_basis_points == 9_985
    assert evaluation.error_budget_total == 10
    assert evaluation.error_budget_remaining == -5
    assert evaluation.budget_remaining_basis_points == -5_000
    assert evaluation.compliance_state == :noncompliant
    assert evaluation.severity == :critical
  end

  test "windows-based SLO evaluation uses good windows as the SLI events" do
    slo = %{
      id: @slo_id,
      slo_kind: :window_based,
      goal_basis_points: 9_900,
      alert_policy: %{"warn_budget_remaining_below_basis_points" => 1_000}
    }

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               period_started_at: @period_started_at,
               period_ended_at: @period_ended_at,
               evaluated_at: @evaluated_at,
               total_windows: 43_200,
               good_windows: 43_000
             })

    assert evaluation.eligible_events == 0
    assert evaluation.good_events == 0
    assert evaluation.total_windows == 43_200
    assert evaluation.good_windows == 43_000
    assert evaluation.bad_windows == 200
    assert evaluation.compliance_basis_points == 9_953
    assert evaluation.error_budget_total == 432
    assert evaluation.error_budget_remaining == 232
    assert evaluation.compliance_state == :compliant
  end

  test "invalid SLO goals fail closed" do
    slo = %{id: @slo_id, slo_kind: :request_based, goal_basis_points: 10_000}

    assert {:error, :invalid_goal_basis_points} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               period_started_at: @period_started_at,
               period_ended_at: @period_ended_at,
               evaluated_at: @evaluated_at,
               eligible_events: 100,
               good_events: 99
             })
  end

  test "partial explicit period bounds fail closed" do
    slo = %{id: @slo_id, slo_kind: :request_based, goal_basis_points: 9_900}

    assert {:error, :incomplete_period_bounds} =
             ServiceLevelObjectiveEvaluator.evaluate(slo, %{
               period_started_at: @period_started_at,
               evaluated_at: @evaluated_at,
               eligible_events: 100,
               good_events: 99
             })
  end
end
