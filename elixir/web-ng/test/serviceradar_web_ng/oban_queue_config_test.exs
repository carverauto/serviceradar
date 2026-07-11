defmodule ServiceRadarWebNG.ObanQueueConfigTest do
  use ExUnit.Case, async: true

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

  defp oban_queues(config) do
    config
    |> Keyword.fetch!(:serviceradar_core)
    |> Keyword.fetch!(Oban)
    |> Keyword.fetch!(:queues)
  end
end
