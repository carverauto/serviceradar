defmodule ServiceRadar.Observability.ZenRuleSyncTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.ZenRuleSync

  test "logs a single transient reconcile message without per-rule warnings" do
    results = [
      {:error, :not_connected, %ZenRule{id: "rule-1", name: "rule-one"}},
      {:error, {:down, :normal}, %ZenRule{id: "rule-2", name: "rule-two"}},
      {:error, GRPC.RPCError.exception(:unknown, ":down: :noproc"),
       %ZenRule{id: "rule-3", name: "rule-three"}},
      {:error, {:rule_bucket, :not_connected}, %ZenRule{id: "rule-4", name: "rule-four"}}
    ]

    log =
      capture_log(fn ->
        ZenRuleSync.log_reconcile_results(results)
      end)

    assert log =~ "Zen rule reconcile skipped due to transient rule store error: count=4"
    refute log =~ "Zen rule reconcile failed for rule"
  end

  test "logs actionable failures and a reconcile summary" do
    results = [
      {:error, {:json_encode_failed, "bad payload"}, %ZenRule{id: "rule-2", name: "rule-two"}},
      {:ok, %ZenRule{id: "rule-3", name: "rule-three"}},
      {:error, {:rule_bucket, %{"code" => 503, "description" => "insufficient resources"}},
       %ZenRule{id: "rule-4", name: "rule-four"}}
    ]

    log =
      capture_log(fn ->
        ZenRuleSync.log_reconcile_results(results)
      end)

    assert log =~
             "Zen rule reconcile failed for rule rule-2 (rule-two): json_encode_failed: bad payload"

    assert log =~
             "Zen rule reconcile failed for rule rule-4 (rule-four): rule bucket serviceradar-zen-rules: " <>
               ~s(%{"code" => 503, "description" => "insufficient resources"})

    assert log =~ "Zen rule reconcile summary: total=3 success=1 failed=2 transient_failed=0"
  end
end
