defmodule ServiceRadarWebNG.ObanQueueConfigTest do
  use ExUnit.Case, async: false

  @moduletag :db_free

  @config_path Path.expand("../../config/config.exs", __DIR__)

  test "runtime queue omission can disable the integrations queue" do
    compile_config = Config.Reader.read!(@config_path, env: :prod, target: :host)
    compile_queues = oban_queues(compile_config)

    refute Keyword.has_key?(compile_queues, :integrations)

    runtime_config = [serviceradar_core: [{Oban, [queues: [default: 1]]}]]
    merged_config = Config.Reader.merge(compile_config, runtime_config)

    refute Keyword.has_key?(oban_queues(merged_config), :integrations)
  end

  test "web release honors durable alert activation and drain settings" do
    names = ~w(SERVICERADAR_ALERT_EVALUATION_MODE SERVICERADAR_ALERT_EVALUATION_PENDING_COUNT SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("SERVICERADAR_ALERT_EVALUATION_PENDING_COUNT", "137")
    System.put_env("SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS", "8")
    System.put_env("SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS", "9")
    runtime = Path.expand("../../config/runtime.exs", __DIR__)

    for mode <- ["active", "draining"] do
      System.put_env("SERVICERADAR_ALERT_EVALUATION_MODE", mode)
      config = Config.Reader.read!(runtime, env: :test, target: :host)
      core = Keyword.fetch!(config, :serviceradar_core)
      expected = if mode == "active", do: :active, else: :draining
      assert core[:alert_evaluation_mode] == expected
      assert core[:alert_evaluation_limits][:pending_count] == 137
      assert core[:alert_evaluation_replay_days] == 8
      assert core[:alert_evaluation_receipt_days] == 9
    end
  end

  defp oban_queues(config) do
    config
    |> Keyword.fetch!(:serviceradar_core)
    |> Keyword.fetch!(Oban)
    |> Keyword.fetch!(:queues)
  end
end
