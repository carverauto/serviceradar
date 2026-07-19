defmodule ServiceRadar.Plugins.AddonRolloutPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonRolloutPolicy

  @moduletag :db_free

  test "normalizes string and atom controls within safety bounds" do
    assert AddonRolloutPolicy.normalize(%{
             "batch_size" => "25",
             canary_size: "0",
             max_parallel: 5_000,
             soak_seconds: -10,
             health_timeout_seconds: "10",
             tolerated_failures: 500
           }) == %{
             "canary_size" => 1,
             "batch_size" => 25,
             "max_parallel" => 1_000,
             "soak_seconds" => 0,
             "health_timeout_seconds" => 30,
             "tolerated_failures" => 100
           }
  end
end
