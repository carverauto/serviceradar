defmodule ServiceRadarAgentGateway.EdgeRecordTrustTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory

  setup do
    on_exit(fn -> EdgeRecordTrust.clear() end)
    %{keys: EdgeRecordFactory.keypair()}
  end

  test "live trust expires and an invalid replacement cannot extend its deadline", %{keys: keys} do
    document = EdgeRecordFactory.trust_document(keys.public)
    now = System.monotonic_time(:millisecond)

    assert :ok = EdgeRecordTrust.install(document, now + 30_000)
    assert EdgeRecordTrust.available?()
    assert :ok = EdgeRecordTrust.install(document, now - 1)
    assert {:error, :trust_unavailable} = EdgeRecordTrust.snapshot()
    refute EdgeRecordTrust.available?()

    assert {:error, :no_keys} = EdgeRecordTrust.install(%{document | "keys" => []}, now + 30_000)
    assert {:error, :trust_unavailable} = EdgeRecordTrust.snapshot()

    assert :ok = EdgeRecordTrust.install(document, now + 30_000)
    assert EdgeRecordTrust.available?()
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
    [key | _registry_key] = valid["keys"]

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

  describe "the contract registry installed with the trust" do
    test "a verified member installs with the document's trust, and the next report names its epochs", %{keys: keys} do
      epoch = EdgeRecordFactory.registry_epoch()
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))

      assert {:ok, %{registry: %{epochs: %{1_000_000 => _}}, registry_refused: []}} = EdgeRecordTrust.snapshot()

      assert EdgeRecordTrust.registry_report("gateway-test-1") == %{
               "gateway_id" => "gateway-test-1",
               "installed" => [
                 %{
                   "registry_epoch" => 1_000_000,
                   "registry_snapshot_sha256" => Base.encode16(epoch.snapshot_sha256, case: :lower)
                 }
               ],
               "refused" => []
             }
    end

    # Decision 12: refuse the member whole, keep the registry verified last, still install trust,
    # and surface the refusal.
    test "a bad signature keeps the previous registry, installs the new trust and reports the refusal",
         %{keys: keys} do
      attach_refusals()
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))

      forged = EdgeRecordFactory.registry_epoch(epoch: 1_000_001, key: IssuerKey.from_seed(:binary.copy(<<0x77>>, 32)))
      forged = %{forged | signing_key_id: EdgeRecordFactory.registry_key().key_id}
      later_fence = {EdgeRecordFactory.uuidv7(), EdgeRecordFactory.uuidv7(), 0, 9}

      bad =
        EdgeRecordFactory.trust_document(keys.public,
          fences: [later_fence],
          contract_registry: EdgeRecordFactory.registry_member([EdgeRecordFactory.registry_epoch(), forged])
        )

      assert :ok = EdgeRecordTrust.install(bad)
      assert {:ok, snapshot} = EdgeRecordTrust.snapshot()

      {scope, assignment, shard, authority} = later_fence
      assert EdgeRecordTrust.fence_relation(snapshot, {scope, assignment, shard}, authority) == :current
      assert Map.keys(snapshot.registry.epochs) == [1_000_000]

      assert %{"installed" => [%{"registry_epoch" => 1_000_000}], "refused" => [refused]} =
               EdgeRecordTrust.registry_report("gateway-test-1")

      assert refused == %{
               "registry_epoch" => 1_000_001,
               "signing_key_id" => Base.encode64(EdgeRecordFactory.registry_key().key_id),
               "reason" => "registry_epoch_signature_invalid"
             }

      assert_received {:registry_refused, %{reason: "registry_epoch_signature_invalid"}}
    end

    test "a fresh gateway whose only document is refused holds no registry", %{keys: keys} do
      tampered = Map.update!(EdgeRecordFactory.registry_epoch(), :epoch, &(&1 + 7))

      document =
        EdgeRecordFactory.trust_document(keys.public, contract_registry: EdgeRecordFactory.registry_member([tampered]))

      assert :ok = EdgeRecordTrust.install(document)
      assert EdgeRecordTrust.available?()
      refute EdgeRecordTrust.registry_available?()
      assert %{"installed" => [], "refused" => [%{"registry_epoch" => 1_000_007}]} = EdgeRecordTrust.registry_report("gw")
    end

    test "a verified member holding no epoch replaces the held registry but is not available", %{keys: keys} do
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))
      assert EdgeRecordTrust.registry_available?()

      empty = EdgeRecordFactory.registry_member([])
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public, contract_registry: empty))

      assert {:ok, %{registry: %{epochs: epochs}}} = EdgeRecordTrust.snapshot()
      assert epochs == %{}
      refute EdgeRecordTrust.registry_available?()
      assert %{"installed" => [], "refused" => []} = EdgeRecordTrust.registry_report("gw")
    end

    test "an unparseable or missing member is refused like a bad signature", %{keys: keys} do
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))

      for member <- [nil, %{"format_version" => 1, "epochs" => []}, %{"format_version" => 2, "epochs" => [%{}]}] do
        assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public, contract_registry: member))
        assert {:ok, %{registry: %{epochs: %{1_000_000 => _}}}} = EdgeRecordTrust.snapshot()
      end
    end

    # The held registry is the one copy reused across documents, so it is verified again under the
    # keys the new document trusts before it is kept.
    test "a held registry whose key the new document no longer trusts is dropped, not kept", %{keys: keys} do
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))
      without_registry_key = EdgeRecordFactory.trust_document(keys.public, contract_registry: nil)
      without_registry_key = %{without_registry_key | "keys" => Enum.take(without_registry_key["keys"], 1)}

      assert :ok = EdgeRecordTrust.install(without_registry_key)
      assert EdgeRecordTrust.available?()
      refute EdgeRecordTrust.registry_available?()
    end

    # The report crosses into core, whose coordinator reads it as readiness evidence; a shape core
    # does not accept would leave every candidate unactivated.
    test "core accepts the installation report the gateway sends", %{keys: keys} do
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
      if !Process.whereis(ServiceRadar.PubSub), do: start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, ContractRegistry.reports_topic())

      forged = %{EdgeRecordFactory.registry_epoch(epoch: 1_000_001) | signature: :binary.copy(<<0>>, 64)}
      member = EdgeRecordFactory.registry_member([EdgeRecordFactory.registry_epoch(), forged])
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public))
      assert :ok = EdgeRecordTrust.install(EdgeRecordFactory.trust_document(keys.public, contract_registry: member))

      assert :ok = ContractRegistry.record_gateway_report(EdgeRecordTrust.registry_report("gateway-test-1"))

      epoch = EdgeRecordFactory.registry_epoch()

      assert_receive {:edge_registry_gateway_report,
                      %{
                        gateway_id: "gateway-test-1",
                        installed: [%{epoch: 1_000_000, snapshot_sha256: snapshot}],
                        refused: [%{epoch: 1_000_001, reason: "registry_epoch_signature_invalid"}]
                      }}

      assert snapshot == epoch.snapshot_sha256
    end
  end

  defp attach_refusals do
    handler = {__MODULE__, self()}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:serviceradar, :agent_gateway, :edge_registry, :signature_rejected],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:registry_refused, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
