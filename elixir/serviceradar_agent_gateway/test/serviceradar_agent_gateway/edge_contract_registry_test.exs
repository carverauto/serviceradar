defmodule ServiceRadarAgentGateway.EdgeContractRegistryTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadarAgentGateway.EdgeContractRegistry
  alias ServiceRadarAgentGateway.EdgeContractRegistry.Static
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub

  @session %{
    authenticated_agent_id: "agent-1",
    route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
    traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
  }

  describe "admit/3" do
    test "admits an active bundle and returns only the route its entry pins" do
      assert {:ok, route} = admit(record())

      assert route == %{
               route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
               traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
               partition_rule: :network_scope_v1
             }
    end

    test "withholds while no registry is loaded" do
      assert {:withhold, :registry_unavailable} =
               EdgeContractRegistry.admit(record(), @session, {:error, :registry_not_configured})
    end

    test "withholds an epoch the gateway does not hold yet, and a stale one, rather than poisoning it" do
      assert {:withhold, :registry_epoch_ahead} = admit(with_contract(record(), registry_epoch: 2))

      loaded = {:ok, %{EdgeContractRegistryStub.snapshot_with(:active) | registry_epoch: 2}}

      assert {:withhold, :registry_epoch_stale} =
               EdgeContractRegistry.admit(with_contract(record(), registry_epoch: 1), @session, loaded)
    end

    test "withholds a same-epoch record naming a different snapshot" do
      assert {:withhold, :registry_snapshot_mismatch} =
               admit(with_contract(record(), registry_snapshot_sha256: :binary.copy(<<0xEE>>, 32)))
    end

    test "rejects a contract the named snapshot does not contain" do
      assert {:reject, :unknown_contract} = admit(with_contract(record(), contract_id: "serviceradar.test.other"))
      assert {:reject, :unknown_contract} = admit(with_contract(record(), contract_version: 2))
    end

    test "rejects a bundle digest that differs from the registered one" do
      assert {:reject, :contract_digest_mismatch} =
               admit(with_contract(record(), contract_bundle_sha256: :binary.copy(<<0xEE>>, 32)))
    end

    test "rejects a record with no output contract" do
      assert {:reject, :contract_missing} = admit(%{record() | output_contract: nil})
    end

    test "withholds every non-active, non-revoked lifecycle state" do
      for state <- [:candidate, :ready, :draining, :retired] do
        loaded = {:ok, EdgeContractRegistryStub.snapshot_with(state)}

        assert {:withhold, {:contract_not_active, ^state}} =
                 EdgeContractRegistry.admit(record(), @session, loaded)
      end
    end

    test "holds a security-revoked bundle, distinct from a withhold" do
      loaded = {:ok, EdgeContractRegistryStub.snapshot_with(:security_revoked)}
      assert {:hold, :security_revoked} = EdgeContractRegistry.admit(record(), @session, loaded)
    end

    test "rejects a route the bundle does not pin, even when the record and lane agree" do
      interactive = %{record() | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
      session = %{@session | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}

      assert {:reject, :route_conflict} =
               EdgeContractRegistry.admit(interactive, session, {:ok, EdgeContractRegistryStub.snapshot_with(:active)})
    end

    test "rejects a cost model the bundle does not pin" do
      assert {:reject, :cost_model_mismatch} = admit(%{record() | cost_model_version: 2})
    end

    test "never trusts provenance the authenticated session contradicts" do
      assert {:reject, :principal_mismatch} =
               admit(%{record() | producer_context: %EdgeProducerContext{origin_principal_id: "agent-2"}})

      assert {:reject, :principal_mismatch} = admit(%{record() | producer_context: nil})

      assert {:reject, :lane_conflict} =
               admit(%{record() | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE})
    end

    test "checks provenance before the registry, so a mismatched session is rejected even with no registry" do
      forged = %{record() | producer_context: %EdgeProducerContext{origin_principal_id: "agent-2"}}

      assert {:reject, :principal_mismatch} =
               EdgeContractRegistry.admit(forged, @session, {:error, :registry_not_configured})
    end
  end

  describe "Static.parse/1" do
    test "parses a snapshot into entries keyed by contract id and version" do
      assert {:ok, snapshot} = Static.parse(json())

      assert snapshot.registry_epoch == 1
      assert snapshot.registry_snapshot_sha256 == :binary.copy(<<0xB2>>, 32)

      assert %{
               state: :active,
               contract_bundle_sha256: bundle,
               route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
               traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
               partition_rule: :network_scope_v1,
               cost_model_version: 1
             } = snapshot.contracts[{"serviceradar.test.sweep", 1}]

      assert bundle == :binary.copy(<<0xB1>>, 32)
    end

    test "an unset registry is not configured" do
      assert {:error, :registry_not_configured} = Static.parse(nil)
      assert {:error, :registry_not_configured} = Static.parse("")
    end

    test "fails closed on the whole snapshot for any malformed part" do
      for {label, doc} <- [
            not_json: "{",
            unknown_key: json(extra: 1),
            missing_key: Jason.encode!(%{"registry_epoch" => 1, "contracts" => []}),
            zero_epoch: json(registry_epoch: 0),
            uppercase_digest: json(registry_snapshot_sha256: String.upcase(hex(0xB2))),
            unknown_state: json_contract(state: "paused"),
            inactive_route: json_contract(route_profile: "EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1"),
            unknown_rule: json_contract(partition_rule: "execution_v1"),
            unknown_contract_key: json_contract(subject: "telemetry.anything"),
            duplicate: json(contracts: [contract_doc(), contract_doc()])
          ] do
        assert {:error, {:invalid_registry, _reason}} = Static.parse(doc), "#{label} was accepted"
      end
    end

    test "snapshot/0 reads the configured document and re-parses when it changes" do
      previous = Application.get_env(:serviceradar_agent_gateway, :edge_record_contract_registry)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:serviceradar_agent_gateway, :edge_record_contract_registry)
          value -> Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry, value)
        end
      end)

      Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry, json())
      assert {:ok, %{registry_epoch: 1}} = Static.snapshot()

      Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry, json(registry_epoch: 7))
      assert {:ok, %{registry_epoch: 7}} = Static.snapshot()

      Application.delete_env(:serviceradar_agent_gateway, :edge_record_contract_registry)
      assert {:error, :registry_not_configured} = Static.snapshot()
    end
  end

  defp admit(record) do
    EdgeContractRegistry.admit(record, @session, {:ok, EdgeContractRegistryStub.snapshot_with(:active)})
  end

  defp record do
    %EdgeRecordV1{
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      output_contract: EdgeContractRegistryStub.contract_ref(),
      producer_context: %EdgeProducerContext{origin_principal_id: "agent-1"},
      cost_model_version: 1
    }
  end

  defp with_contract(record, fields), do: %{record | output_contract: struct(record.output_contract, fields)}

  defp hex(byte), do: Base.encode16(:binary.copy(<<byte>>, 32), case: :lower)

  defp contract_doc(overrides \\ []) do
    Map.merge(
      %{
        "contract_id" => "serviceradar.test.sweep",
        "contract_version" => 1,
        "contract_bundle_sha256" => hex(0xB1),
        "state" => "active",
        "route_profile" => "EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1",
        "traffic_class" => "EDGE_RECORD_TRAFFIC_CLASS_BULK",
        "partition_rule" => "network_scope_v1",
        "cost_model_version" => 1
      },
      Map.new(overrides, fn {k, v} -> {Atom.to_string(k), v} end)
    )
  end

  defp json(overrides \\ []) do
    %{
      "registry_epoch" => 1,
      "registry_snapshot_sha256" => hex(0xB2),
      "contracts" => [contract_doc()]
    }
    |> Map.merge(Map.new(overrides, fn {k, v} -> {Atom.to_string(k), v} end))
    |> Jason.encode!()
  end

  defp json_contract(overrides), do: json(contracts: [contract_doc(overrides)])
end
