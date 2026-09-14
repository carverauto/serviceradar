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

    assert snapshot.trust_policy_epoch == 1

    assert {:ok, public_key, :valid} =
             EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", EdgeRecordFactory.issuer_key_id(), :production)

    assert public_key == keys.public
    assert {:error, :key_invalid} = EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", "other-key", :production)
  end

  test "a key resolves only for the purposes it may issue", %{keys: keys} do
    document = EdgeRecordFactory.trust_document(keys.public, purposes: ["delivery"])
    {:ok, snapshot} = EdgeRecordTrust.new(document)

    key_id = EdgeRecordFactory.issuer_key_id()
    assert {:ok, _, :valid} = EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", key_id, :delivery)
    assert {:error, :key_invalid} = EdgeRecordTrust.resolve_key(snapshot, "test-edge-issuer", key_id, :production)
  end

  test "rejects documents that could not pin a decision", %{keys: keys} do
    valid = EdgeRecordFactory.trust_document(keys.public)
    [key] = valid["keys"]

    assert {:error, :trust_policy_epoch} = EdgeRecordTrust.new(%{valid | "trust_policy_epoch" => 0})
    assert {:error, :no_keys} = EdgeRecordTrust.new(%{valid | "keys" => []})
    assert {:error, :duplicate_key} = EdgeRecordTrust.new(%{valid | "keys" => [key, key]})

    assert {:error, :public_key} =
             EdgeRecordTrust.new(%{valid | "keys" => [%{key | "public_key" => Base.encode64("short")}]})

    assert {:error, :purpose} = EdgeRecordTrust.new(%{valid | "keys" => [%{key | "purposes" => ["collection"]}]})
    assert {:error, :status} = EdgeRecordTrust.new(%{valid | "keys" => [%{key | "status" => "retired"}]})
    assert {:error, :clock_tolerance} = EdgeRecordTrust.new(Map.put(valid, "clock_tolerance_nano", -1))
  end

  test "classifies producer epochs against advanced fences, and treats an unfenced producer as current", %{keys: keys} do
    scope = EdgeRecordFactory.uuidv7()
    assignment = EdgeRecordFactory.uuidv7()
    document = EdgeRecordFactory.trust_document(keys.public, fences: [{scope, assignment, 0, 5}])
    {:ok, snapshot} = EdgeRecordTrust.new(document)

    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 4) == :stale
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 5) == :current
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 0}, 6) == :future
    assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, 1}, 1) == :current
  end

  test "installs from a JSON file, and an invalid file leaves nothing installed", %{keys: keys} do
    dir = Path.join(System.tmp_dir!(), "edge-record-trust-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    good = Path.join(dir, "trust.json")
    File.write!(good, Jason.encode!(EdgeRecordFactory.trust_document(keys.public)))
    bad = Path.join(dir, "bad.json")
    File.write!(bad, ~s({"trust_policy_epoch": 0}))

    EdgeRecordTrust.clear()
    refute EdgeRecordTrust.available?()

    assert {:error, :trust_policy_epoch} = EdgeRecordTrust.load_file(bad)
    refute EdgeRecordTrust.available?()

    assert :ok = EdgeRecordTrust.load_file(good)
    assert EdgeRecordTrust.available?()
  end
end
