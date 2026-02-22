defmodule ServiceRadar.Plugins.TargetBatchParamsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.TargetBatchParams

  test "validate accepts non-batch params" do
    assert :ok = TargetBatchParams.validate(%{"foo" => "bar"})
  end

  test "validate accepts valid batch params" do
    payload = %{
      "schema" => TargetBatchParams.schema_id(),
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "chunk_index" => 0,
      "chunk_total" => 1,
      "chunk_hash" => String.duplicate("a", 64),
      "generated_at" => "2026-02-21T20:00:00Z",
      "targets" => [
        %{"uid" => "sr:device:1", "ip" => "10.0.0.1"},
        %{"uid" => "sr:device:2", "ip" => "10.0.0.2"}
      ]
    }

    assert :ok = TargetBatchParams.validate(payload)
  end

  test "validate rejects invalid batch payload" do
    payload = %{
      "schema" => TargetBatchParams.schema_id(),
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "chunk_index" => 0,
      "chunk_total" => 1,
      "chunk_hash" => "bad",
      "generated_at" => "2026-02-21T20:00:00Z",
      "targets" => [%{"ip" => "10.0.0.1"}]
    }

    assert {:error, errors} = TargetBatchParams.validate(payload)
    assert Enum.any?(errors, &String.contains?(&1, "chunk_hash"))
  end

  test "chunk_targets_with_limits builds deterministic payloads" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 2,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T20:00:00Z",
      "template" => %{"timeout" => "5s"}
    }

    targets =
      Enum.map(1..5, fn idx ->
        %{"uid" => "sr:device:#{idx}", "ip" => "10.0.0.#{idx}"}
      end)

    assert {:ok, payloads} =
             TargetBatchParams.chunk_targets_with_limits(base, targets, chunk_size: 2)

    assert length(payloads) == 3

    assert Enum.map(payloads, & &1["chunk_index"]) == [0, 1, 2]
    assert Enum.all?(payloads, &(&1["chunk_total"] == 3))

    assert Enum.all?(
             payloads,
             &(is_binary(&1["chunk_hash"]) and byte_size(&1["chunk_hash"]) == 64)
           )

    # deterministic hash for same input
    assert {:ok, payloads_again} =
             TargetBatchParams.chunk_targets_with_limits(base, targets, chunk_size: 2)

    assert Enum.map(payloads, & &1["chunk_hash"]) == Enum.map(payloads_again, & &1["chunk_hash"])
  end

  test "chunk_targets_with_limits re-chunks when payload exceeds hard limit" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 2,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T20:00:00Z"
    }

    targets =
      Enum.map(1..4, fn idx ->
        %{
          "uid" => "sr:device:#{idx}",
          "ip" => "10.0.0.#{idx}",
          "hostname" => String.duplicate("x", 500)
        }
      end)

    assert {:ok, payloads} =
             TargetBatchParams.chunk_targets_with_limits(base, targets,
               chunk_size: 4,
               hard_limit_bytes: 900
             )

    assert length(payloads) > 1

    assert Enum.all?(payloads, fn payload ->
             TargetBatchParams.payload_size_bytes(payload) <= 900
           end)
  end
end
