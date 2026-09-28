defmodule ServiceRadarAgentGateway.EdgeRecordTrustTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory

  setup do
    on_exit(fn -> EdgeRecordTrust.clear() end)
    %{keys: EdgeRecordFactory.keypair()}
  end

  test "a valid document becomes a snapshot keyed by exact issuer and key id", %{keys: keys} do
    assert {:ok, snapshot} = EdgeRecordTrust.new(EdgeRecordFactory.trust_document(keys.public))

    assert {:ok, public_key, :valid} =
             EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", EdgeRecordFactory.issuer_key_id(), :production)

    assert public_key == keys.public

    assert {:error, :key_unavailable} =
             EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", "other-key", :production)
  end

  test "a key resolves only for the purposes it may issue", %{keys: keys} do
    document = EdgeRecordFactory.trust_document(keys.public, purposes: ["delivery"])
    {:ok, snapshot} = EdgeRecordTrust.new(document)

    key_id = EdgeRecordFactory.issuer_key_id()
    assert {:ok, _, :valid} = EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", key_id, :delivery)

    assert {:error, :key_purpose_unavailable} =
             EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", key_id, :production)
  end

  test "rejects documents that could not authorize a decision", %{keys: keys} do
    valid = EdgeRecordFactory.trust_document(keys.public)
    [key] = valid["keys"]

    assert {:error, :document} = EdgeRecordTrust.new([valid])
    assert {:error, :no_keys} = EdgeRecordTrust.new(%{valid | "keys" => []})
    assert {:error, :duplicate_key} = EdgeRecordTrust.new(%{valid | "keys" => [key, key]})

    assert {:error, :public_key} =
             EdgeRecordTrust.new(%{valid | "keys" => [%{key | "public_key" => Base.encode64("short")}]})

    assert {:error, :purpose} = EdgeRecordTrust.new(%{valid | "keys" => [%{key | "purposes" => ["collection"]}]})
    assert {:error, :status} = EdgeRecordTrust.new(%{valid | "keys" => [%{key | "status" => "retired"}]})
    assert {:error, :clock_tolerance} = EdgeRecordTrust.new(Map.put(valid, "clock_tolerance_nano", -1))
  end

  test "classifies producer epochs against their fence, and never reads an unfenced producer as current", %{keys: keys} do
    scope = EdgeRecordFactory.uuidv7()
    assignment = EdgeRecordFactory.uuidv7()
    document = EdgeRecordFactory.trust_document(keys.public, fences: [{scope, assignment, 0, 5}])
    {:ok, snapshot} = EdgeRecordTrust.new(document)

    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 4) == :stale
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 5) == :current
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 6) == :future
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 1}, 5) == :unavailable
    assert EdgeRecordTrust.fence_relation(snapshot, {EdgeRecordFactory.uuidv7(), assignment, 0}, 5) == :unavailable
  end

  test "binds each agent principal to its network scopes, and leaves any other principal unbound", %{keys: keys} do
    first = EdgeRecordFactory.uuidv7()
    second = EdgeRecordFactory.uuidv7()
    document = EdgeRecordFactory.trust_document(keys.public, scopes: [{"agent-1", [first, second]}])
    {:ok, snapshot} = EdgeRecordTrust.new(document)

    assert %{component_id: "agent-1", network_scope_ids: scopes} =
             EdgeRecordTrust.with_network_scopes(snapshot, %{component_id: "agent-1"})

    assert scopes == MapSet.new([first, second])
    assert %{network_scope_ids: nil} = EdgeRecordTrust.with_network_scopes(snapshot, %{component_id: "agent-2"})
  end

  test "rejects scope bindings that could not bind one exact principal to exact scopes", %{keys: keys} do
    valid = EdgeRecordFactory.trust_document(keys.public, scopes: [{"agent-1", [EdgeRecordFactory.uuidv7()]}])
    [binding] = valid["scopes"]
    with_binding = fn changes -> %{valid | "scopes" => [Map.merge(binding, changes)]} end

    assert {:error, :duplicate_scope_binding} = EdgeRecordTrust.new(%{valid | "scopes" => [binding, binding]})
    assert {:error, :agent_id} = EdgeRecordTrust.new(with_binding.(%{"agent_id" => "agent.1"}))
    assert {:error, :scope_binding} = EdgeRecordTrust.new(with_binding.(%{"network_scope_ids" => []}))

    assert {:error, :network_scope_id} =
             EdgeRecordTrust.new(with_binding.(%{"network_scope_ids" => [Base.encode64(<<0::128>>)]}))

    assert {:error, :duplicate_network_scope} =
             EdgeRecordTrust.new(
               with_binding.(%{"network_scope_ids" => binding["network_scope_ids"] ++ binding["network_scope_ids"]})
             )
  end

  test "installs from a JSON file, and an invalid file leaves nothing installed", %{keys: keys} do
    dir = Path.join(System.tmp_dir!(), "edge-record-trust-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    good = Path.join(dir, "trust.json")
    File.write!(good, Jason.encode!(EdgeRecordFactory.trust_document(keys.public)))
    bad = Path.join(dir, "bad.json")
    File.write!(bad, ~s({"keys": []}))

    EdgeRecordTrust.clear()
    refute EdgeRecordTrust.available?()

    assert {:error, :no_keys} = EdgeRecordTrust.load_file(bad)
    refute EdgeRecordTrust.available?()

    assert :ok = EdgeRecordTrust.load_file(good)
    assert EdgeRecordTrust.available?()
  end
end
