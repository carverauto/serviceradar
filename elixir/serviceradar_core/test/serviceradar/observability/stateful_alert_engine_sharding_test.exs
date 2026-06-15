defmodule ServiceRadar.Observability.StatefulAlertEngineShardingTest do
  @moduledoc """
  Pure (DB-free) tests for the engine's rule sharding logic.

  Sharding is what removes the single-GenServer serialization point: a rule's
  entire state machine lives in exactly one shard, so disjoint rules no longer
  contend on one process and their DB writes parallelize across shards. These
  tests pin down the sharding contract that makes that safe.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine

  setup do
    previous = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, :stateful_alert_engine_shards)
        value -> Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, value)
      end
    end)

    :ok
  end

  test "shard_count honors configuration and falls back to a positive default" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 4)
    assert StatefulAlertEngine.shard_count() == 4

    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 0)
    assert StatefulAlertEngine.shard_count() > 0

    Application.delete_env(:serviceradar_core, :stateful_alert_engine_shards)
    assert StatefulAlertEngine.shard_count() > 0
  end

  test "shard_for_rule_id is deterministic and within range" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 8)

    rule_ids = for _ <- 1..200, do: Ash.UUID.generate()

    for rule_id <- rule_ids do
      shard = StatefulAlertEngine.shard_for_rule_id(rule_id)
      assert shard in 0..7
      # Same id always maps to the same shard (a rule never splits across shards).
      assert shard == StatefulAlertEngine.shard_for_rule_id(rule_id)
    end
  end

  test "rule ids distribute across more than one shard" do
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 8)

    for_result =
      for _ <- 1..500 do
        StatefulAlertEngine.shard_for_rule_id(Ash.UUID.generate())
      end

    shards = Enum.uniq(for_result)

    # With 500 random ids and 8 shards, we expect the work to spread out; a
    # single shard would mean no parallelism.
    assert length(shards) > 1
  end
end
