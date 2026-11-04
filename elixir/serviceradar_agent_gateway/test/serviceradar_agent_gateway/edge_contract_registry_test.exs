defmodule ServiceRadarAgentGateway.EdgeContractRegistryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadarAgentGateway.EdgeContractRegistry
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  @session %{
    authenticated_agent_id: "agent-1",
    route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
    traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
  }
  @draining 1_000_000
  @active 1_000_001

  describe "admit/3" do
    test "admits a record under its epoch's entry and returns only the route that entry pins" do
      assert {:ok, route} = admit(record(), registry!())

      assert route == %{
               route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
               traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
               partition_rule: :network_scope_v1
             }
    end

    # Decision 5: a draining epoch's backlog drains under ITS exact bundle after the active epoch
    # changed that contract, and neither epoch's bundle is accepted under the other.
    test "admits a draining epoch's record under that epoch's bundle after a newer epoch changed it" do
      {draining, active} = changed_bundle_epochs()
      registry = registry!([draining, active])

      assert {:ok, _route} = admit(record(Factory.contract_ref(draining)), registry)
      assert {:ok, _route} = admit(record(Factory.contract_ref(active)), registry)

      old_bundle_under_new_epoch = %{Factory.contract_ref(active) | contract_bundle_sha256: bundle(draining)}
      assert {:reject, :contract_digest_mismatch} = admit(record(old_bundle_under_new_epoch), registry)
    end

    test "admits under a candidate epoch, since lifecycle is per epoch and core decides what it signs" do
      candidate = Factory.registry_epoch(epoch: @active, state: :candidate)

      assert {:ok, _route} =
               admit(record(Factory.contract_ref(candidate)), registry!([Factory.registry_epoch(), candidate]))
    end

    test "withholds an epoch newer than every epoch held, rather than poisoning it" do
      ahead = %{Factory.contract_ref() | registry_epoch: @active}
      assert {:withhold, :registry_epoch_ahead} = admit(record(ahead), registry!())
    end

    test "rejects a retired epoch permanently, whether the document drops it or marks it retired" do
      {draining, active} = changed_bundle_epochs()

      assert {:reject, :registry_epoch_retired} =
               admit(record(Factory.contract_ref(draining)), registry!([active]))

      assert {:reject, :registry_epoch_retired} =
               admit(record(Factory.contract_ref(draining)), registry!([%{draining | state: :retired}, active]))
    end

    test "rejects an installation-static epoch permanently, even with no registry held" do
      static = %{Factory.contract_ref() | registry_epoch: 2}

      assert {:reject, :static_registry_epoch} = admit(record(static), registry!())
      assert {:reject, :static_registry_epoch} = admit(record(static), nil)
    end

    test "withholds every other record while no registry is verified" do
      assert {:withhold, :registry_unavailable} = admit(record(), nil)
    end

    # Core sends an empty member before its first epoch exists; an ahead withhold would cap the lane
    # for a record signed under that first epoch.
    test "withholds a record as unavailable while the verified registry holds no epoch" do
      assert {:withhold, :registry_unavailable} = admit(record(), registry!([]))
    end

    # The epoch's document is signed and immutable, so a mismatch under a held epoch can never
    # clear; withholding it would cap the lane for good.
    test "rejects what a held epoch does not sign: its snapshot, contract or bundle" do
      registry = registry!()
      ref = Factory.contract_ref()

      for {fields, reason} <- [
            {%{registry_snapshot_sha256: :binary.copy(<<0xEE>>, 32)}, :registry_snapshot_mismatch},
            {%{contract_id: "serviceradar.test.other"}, :unknown_contract},
            {%{contract_version: 2}, :unknown_contract},
            {%{contract_bundle_sha256: :binary.copy(<<0xEE>>, 32)}, :contract_digest_mismatch}
          ] do
        assert {:reject, ^reason} = admit(record(struct(ref, fields)), registry)
      end
    end

    test "rejects a record with no output contract" do
      assert {:reject, :contract_missing} = admit(%{record() | output_contract: nil}, registry!())
    end

    test "rejects a route or cost model the entry does not pin, even when the record and lane agree" do
      interactive = %{record() | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
      session = %{@session | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}

      assert {:reject, :route_conflict} = EdgeContractRegistry.admit(interactive, session, registry!())
      assert {:reject, :cost_model_mismatch} = admit(%{record() | cost_model_version: 2}, registry!())
    end

    test "withholds a bundle outside the projectable set, and admits one inside it" do
      {draining, active} = changed_bundle_epochs()
      registry = registry!([draining, active], projectable_bundles: [bundle(active)])

      assert {:withhold, :bundle_not_projectable} = admit(record(Factory.contract_ref(draining)), registry)
      assert {:ok, _route} = admit(record(Factory.contract_ref(active)), registry)
    end

    test "never trusts provenance the authenticated session contradicts, with or without a registry" do
      impostor = %{record() | producer_context: %EdgeProducerContext{origin_principal_id: "agent-2"}}

      assert {:reject, :principal_mismatch} = admit(impostor, registry!())
      assert {:reject, :principal_mismatch} = admit(impostor, nil)
      assert {:reject, :principal_mismatch} = admit(%{record() | producer_context: nil}, registry!())

      assert {:reject, :lane_conflict} =
               admit(%{record() | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}, registry!())
    end
  end

  describe "verify_member/2" do
    test "refuses the whole member when one epoch's signed contents were altered" do
      {draining, active} = changed_bundle_epochs()
      [_draining_item, active_item] = Factory.registry_member([draining, active])["epochs"]
      [entry] = active_item["contracts"]

      for tampered <- [
            %{entry | "cost_model_version" => 2},
            %{entry | "projection_revision" => 1},
            %{entry | "contract_bundle_sha256" => Base.encode16(bundle(draining), case: :lower)}
          ] do
        member = member_with([draining, active], 1, %{active_item | "contracts" => [tampered]})

        assert {:error, :registry_epoch_signature_invalid, [%{epoch: @active}]} =
                 EdgeContractRegistry.verify_member(member, trusted_keys())
      end
    end

    test "refuses an epoch signed under a key id the document does not trust" do
      stranger = IssuerKey.from_seed(:binary.copy(<<0x6A>>, 32))
      epoch = Factory.registry_epoch(key: stranger)

      assert {:error, :registry_epoch_signing_key_unknown, [%{epoch: @draining, signing_key_id: key_id}]} =
               EdgeContractRegistry.verify_member(Factory.registry_member([epoch]), trusted_keys())

      assert key_id == stranger.key_id
    end

    test "fails closed on a malformed member" do
      valid = Factory.registry_member()
      [item] = valid["epochs"]

      for {label, member, reason} <- [
            {:not_a_map, [valid], :registry_member},
            {:missing, nil, :registry_member_missing},
            {:unknown_key, Map.put(valid, "extra", 1), :registry_member},
            {:format_version, %{valid | "format_version" => 1}, :registry_format_version},
            {:duplicate_epoch, %{valid | "epochs" => [item, item]}, :registry_epoch_duplicate},
            {:malformed_epoch, %{valid | "epochs" => [Map.delete(item, "state")]}, :registry_epoch_malformed},
            {:projectable_not_hex, Map.put(valid, "projectable_bundles", ["zz"]), :registry_projectable_bundles},
            {:projectable_duplicate, Map.put(valid, "projectable_bundles", List.duplicate(String.duplicate("ab", 32), 2)),
             :registry_projectable_bundles}
          ] do
        assert {:error, ^reason, _refused} = EdgeContractRegistry.verify_member(member, trusted_keys()),
               "#{label} was accepted"
      end
    end
  end

  # Epoch @draining holds the default contract; epoch @active changed it at the same contract
  # version, with a new bundle and a higher projection revision.
  defp changed_bundle_epochs do
    draining = Factory.registry_epoch(epoch: @draining, state: :draining)

    active =
      Factory.registry_epoch(
        epoch: @active,
        entries: [Factory.contract_entry(%{contract_bundle_sha256: :binary.copy(<<0xC1>>, 32), projection_revision: 2})]
      )

    {draining, active}
  end

  defp bundle(epoch), do: epoch.contracts |> Map.values() |> hd() |> Map.fetch!(:contract_bundle_sha256)

  defp member_with(epochs, index, item) do
    member = Factory.registry_member(epochs)
    %{member | "epochs" => List.replace_at(member["epochs"], index, item)}
  end

  defp trusted_keys do
    key = Factory.registry_key()
    %{key.key_id => key.public_key}
  end

  defp registry!(epochs \\ [Factory.registry_epoch()], opts \\ []) do
    {:ok, registry} = EdgeContractRegistry.verify_member(Factory.registry_member(epochs, opts), trusted_keys())
    registry
  end

  defp admit(record, registry), do: EdgeContractRegistry.admit(record, @session, registry)

  defp record(contract \\ Factory.contract_ref()) do
    %EdgeRecordV1{
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      output_contract: contract,
      producer_context: %EdgeProducerContext{origin_principal_id: "agent-1"},
      cost_model_version: 1
    }
  end
end
