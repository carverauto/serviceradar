defmodule ServiceRadar.Observability.AlertEvaluationRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout

  @names ~w(SERVICERADAR_ALERT_EVALUATION_MODE SERVICERADAR_ALERT_EVALUATION_ADMISSION_TIMEOUT_MS SERVICERADAR_ALERT_EVALUATION_BATCH_RECORDS SERVICERADAR_ALERT_EVALUATION_BATCH_WORK SERVICERADAR_ALERT_EVALUATION_PENDING_COUNT SERVICERADAR_ALERT_EVALUATION_PENDING_BYTES SERVICERADAR_ALERT_EVALUATION_RULE_COUNT SERVICERADAR_ALERT_EVALUATION_RULE_BYTES SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS)

  setup do
    previous = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "startup defaults to prepared and requires receipt retention to cover replay" do
    config = Rollout.runtime_config!()
    assert config[:alert_evaluation_mode] == :prepared
    assert config[:alert_evaluation_limits] == []
    assert config[:alert_evaluation_receipt_days] >= config[:alert_evaluation_replay_days]

    System.put_env("SERVICERADAR_ALERT_EVALUATION_MODE", "draining")
    System.put_env("SERVICERADAR_ALERT_EVALUATION_PENDING_COUNT", "120")
    System.put_env("SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS", "8")
    System.put_env("SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS", "9")
    config = Rollout.runtime_config!()
    assert config[:alert_evaluation_mode] == :draining
    assert config[:alert_evaluation_limits] == [pending_count: 120]
    assert config[:alert_evaluation_receipt_days] == 9

    System.put_env("SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS", "7")
    assert_raise ArgumentError, fn -> Rollout.runtime_config!() end
  end

  test "invalid startup bounds and unknown modes fail before consumers start" do
    for name <- @names -- ["SERVICERADAR_ALERT_EVALUATION_MODE"], value <- ["0", "-1", "1ms"] do
      System.put_env(name, value)
      assert_raise ArgumentError, fn -> Rollout.runtime_config!() end
      System.delete_env(name)
    end

    System.put_env("SERVICERADAR_ALERT_EVALUATION_MODE", "automatic")
    assert_raise ArgumentError, fn -> Rollout.runtime_config!() end
  end
end
