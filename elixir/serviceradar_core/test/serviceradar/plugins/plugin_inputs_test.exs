defmodule ServiceRadar.Plugins.PluginInputsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginInputs

  test "validate accepts non-plugin-input payloads" do
    assert :ok = PluginInputs.validate(%{"foo" => "bar"})
  end

  test "validate accepts valid plugin inputs payload" do
    payload = %{
      "schema" => PluginInputs.schema_id(),
      "policy_id" => "policy-1",
      "policy_version" => 3,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T21:00:00Z",
      "inputs" => [
        %{
          "name" => "targets",
          "entity" => "devices",
          "query" => "in:devices type:camera",
          "chunk_index" => 0,
          "chunk_total" => 1,
          "chunk_hash" => String.duplicate("b", 64),
          "items" => [%{"uid" => "sr:device:1", "ip" => "10.0.0.1"}]
        }
      ]
    }

    assert :ok = PluginInputs.validate(payload)
  end

  test "validate rejects missing required input fields" do
    payload = %{
      "schema" => PluginInputs.schema_id(),
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T21:00:00Z",
      "inputs" => [%{"name" => "targets", "entity" => "devices", "items" => [%{"uid" => "x"}]}]
    }

    assert {:error, errors} = PluginInputs.validate(payload)
    assert Enum.any?(errors, &String.contains?(&1, "query"))
  end

  test "chunk_single_input_payloads creates deterministic chunk hashes" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T21:00:00Z"
    }

    input = %{
      "name" => "targets",
      "entity" => "devices",
      "query" => "in:devices type:camera"
    }

    items =
      Enum.map(1..5, fn idx ->
        %{"uid" => "sr:device:#{idx}", "ip" => "10.0.0.#{idx}"}
      end)

    assert {:ok, payloads_a} =
             PluginInputs.chunk_single_input_payloads(base, input, items, chunk_size: 2)

    assert {:ok, payloads_b} =
             PluginInputs.chunk_single_input_payloads(base, input, items, chunk_size: 2)

    assert length(payloads_a) == 3

    hashes_a = Enum.map(payloads_a, fn p -> hd(p["inputs"])["chunk_hash"] end)
    hashes_b = Enum.map(payloads_b, fn p -> hd(p["inputs"])["chunk_hash"] end)
    assert hashes_a == hashes_b
  end

  test "chunk_single_input_payloads re-chunks to fit size limits" do
    base = %{
      "policy_id" => "policy-1",
      "policy_version" => 1,
      "agent_id" => "agent-1",
      "generated_at" => "2026-02-21T21:00:00Z"
    }

    input = %{
      "name" => "interfaces",
      "entity" => "interfaces",
      "query" => "in:interfaces"
    }

    items =
      Enum.map(1..4, fn idx ->
        %{"id" => "if-#{idx}", "description" => String.duplicate("z", 600)}
      end)

    assert {:ok, payloads} =
             PluginInputs.chunk_single_input_payloads(base, input, items,
               chunk_size: 4,
               hard_limit_bytes: 1200
             )

    assert length(payloads) > 1

    assert Enum.all?(payloads, fn payload ->
             PluginInputs.payload_size_bytes(payload) <= 1200
           end)
  end
end
