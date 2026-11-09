defmodule ServiceRadar.Edge.LocalBindingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.LocalBinding
  alias ServiceRadar.Edge.RecoveryAttribution
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationKind
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch

  @fixtures Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  test "the independent shared local binding corpus pins every transcript axis" do
    %{"vectors" => [_ | _] = vectors} = JSON.decode!(load("local_binding_corpus.json"))

    for vector <- vectors do
      {coordinates, attribution} = corpus_input(vector)
      result = LocalBinding.digest(vector["version"], coordinates, attribution)

      case vector do
        %{"digest" => digest} ->
          assert result == {:ok, hex(digest)}, vector["name"]

        %{"error" => "local_binding"} ->
          assert result == {:error, :local_binding}, vector["name"]

        %{"error" => "local_binding_version"} ->
          assert result == {:error, :local_binding_version}, vector["name"]
      end
    end

    assert {:error, :local_binding_version} = LocalBinding.digest(2, nil, nil)
  end

  for {contract, fixture, active} <- [
        {:sweep, "sweep_join_positive_scheduled_sweep.bin", true},
        {:control, "version_tombstone_scope_ok.bin", false}
      ] do
    test "#{contract} constructor binds complete attribution and relocation coordinates" do
      {record, raw, policy} = signed_fixture(unquote(fixture))

      assert {:ok, validated} =
               apply(RecoveryAttribution, unquote(contract), [raw, record.output_contract, policy])

      if unquote(contract) == :sweep do
        assert {:ok, ^validated} =
                 RecoveryAttribution.registered(raw, record.output_contract, policy)
      end

      a = RecoveryAttribution.attribution(validated)
      assert a.active == unquote(active)
      assert %EdgeSourceSpanIdentityV1{} = a.identity.source
      c = coordinates(record, raw)
      assert {:ok, original} = RecoveryAttribution.bind(validated, c, a)

      mutations = [
        %{a | identity: %{a.identity | production_scope_id: uuid(31)}},
        %{a | identity: %{a.identity | scope_sha256: digest(32)}},
        %{a | identity: %{a.identity | contract_bundle_sha256: digest(33)}},
        %{a | identity: %{a.identity | producer_assignment_id: uuid(34)}},
        %{a | identity: %{a.identity | run_id: uuid(35)}},
        %{a | identity: %{a.identity | run_shard: a.identity.run_shard + 1}},
        %{a | identity: %{a.identity | authority_epoch: a.identity.authority_epoch + 1}},
        %{a | active: not a.active},
        %{a | identity: %{a.identity | source: nil}},
        %{a | identity: %{a.identity | source: %{a.identity.source | source_scope_id: uuid(36)}}},
        %{
          a
          | identity: %{
              a.identity
              | source: %{a.identity.source | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC}
            }
        },
        %{a | identity: %{a.identity | source: %{a.identity.source | context_id: uuid(37)}}},
        %{
          a
          | identity: %{
              a.identity
              | source: %{a.identity.source | source_scope_sha256: digest(38)}
            }
        }
      ]

      for changed <- mutations do
        assert {:error, :attribution_join} = RecoveryAttribution.bind(validated, c, changed)
      end

      if a.active do
        assert {:error, :attribution_join} =
                 RecoveryAttribution.bind(validated, c, %{a | range_sha256: digest(39)})
      end

      for changed <- [
            %{c | network_scope_id: uuid(40)},
            %{c | authenticated_agent_id: "other_synthetic_agent"},
            %{c | event_id: uuid(41)},
            %{c | record_sha256: digest(42)},
            %{c | lane_traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
          ] do
        assert {:error, :attribution_join} = RecoveryAttribution.bind(validated, changed, a)
      end

      assert {:ok, rebound} =
               RecoveryAttribution.bind(validated, %{c | spool_generation_id: uuid(43)}, a)

      refute rebound == original
    end
  end

  test "constructor refuses a signed body with substituted range identity" do
    {record, raw, policy} = signed_fixture("sweep_join_range_id.bin")

    assert {:error, {:correlation, :range_id}} =
             RecoveryAttribution.sweep(raw, record.output_contract, policy)
  end

  test "standing metrics derive passive attribution without a source identity" do
    record = EdgeRecordV1.decode(load("record_no_source.bin"))

    contract = %{
      record.output_contract
      | contract_id: "serviceradar.metrics.batch",
        contract_version: 1
    }

    {:production, claims} = record.production_capability.claims

    claims = %{
      claims
      | contract_id: contract.contract_id,
        contract_version: contract.contract_version
    }

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        ingest_identity: %IngestIdentity{source: "sysmon-metrics"},
        metrics: [%Metric{name: "cpu.usage_percent", metric_type: "sysmon.cpu"}]
      })

    record = %{
      record
      | output_contract: contract,
        production_capability: %{record.production_capability | claims: {:production, claims}},
        payload: payload,
        payload_sha256: :crypto.hash(:sha256, payload),
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        projected_row_count: 1,
        projected_write_bytes: 1024
    }

    {record, raw, policy} = signed_record(record)
    assert {:ok, validated} = RecoveryAttribution.metrics(raw, policy)
    assert {:ok, ^validated} = RecoveryAttribution.registered(raw, record.output_contract, policy)

    assert %{classification: {:attributed_passive, %{identity: %{source: nil}}}} =
             RecoveryAttribution.classification(validated)

    {wrong_cost, wrong_bytes, wrong_policy} = signed_record(%{record | projected_row_count: 2})

    assert {:error, _reason} =
             RecoveryAttribution.registered(wrong_bytes, wrong_cost.output_contract, wrong_policy)

    assert {:error, :contract_dispatch} =
             RecoveryAttribution.registered(
               raw,
               %{record.output_contract | contract_bundle_sha256: digest(49)},
               policy
             )

    for {id, version} <- [{"synthetic.unknown.contract", 1}, {"serviceradar.metrics.batch", 2}] do
      {:production, claims} = record.production_capability.claims
      claims = %{claims | contract_id: id, contract_version: version}

      changed = %{
        record
        | output_contract: %{record.output_contract | contract_id: id, contract_version: version},
          production_capability: %{record.production_capability | claims: {:production, claims}}
      }

      {changed, bytes, changed_policy} = signed_record(changed)

      assert {:error, :contract_dispatch} =
               RecoveryAttribution.registered(bytes, changed.output_contract, changed_policy)
    end

    assert %{active: false, range_sha256: "", identity: %{source: nil}} =
             a = RecoveryAttribution.attribution(validated)

    c = coordinates(record, raw)
    assert {:ok, _digest} = RecoveryAttribution.bind(validated, c, a)

    for changed <- [
          %{a | active: true, range_sha256: digest(44)},
          %{a | identity: %{a.identity | production_scope_id: uuid(45)}},
          %{
            a
            | identity: %{
                a.identity
                | source: %EdgeSourceSpanIdentityV1{
                    kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
                    context_id: uuid(46),
                    source_scope_id: uuid(47),
                    source_scope_sha256: digest(48)
                  }
              }
          }
        ] do
      assert {:error, :attribution_join} = RecoveryAttribution.bind(validated, c, changed)
    end
  end

  defp corpus_input(v) do
    c = v["coordinates"]
    a = v["attribution"]
    i = a["identity"]

    coordinates = %{
      network_scope_id: hex(c["network_scope_id"]),
      authenticated_agent_id: c["authenticated_agent_id"],
      lane_route_profile: EdgeRecordRouteProfile.key(c["lane_route_profile"]),
      lane_traffic_class: EdgeRecordTrafficClass.key(c["lane_traffic_class"]),
      spool_generation_id: hex(c["spool_generation_id"]),
      sequence: c["sequence"],
      event_id: hex(c["event_id"]),
      record_sha256: hex(c["record_sha256"])
    }

    attribution = %{
      active: a["active"],
      range_sha256: hex(a["range_sha256"]),
      identity: %EdgeAttributedSpanIdentityV1{
        contract_bundle_sha256: hex(i["contract_bundle_sha256"]),
        producer_assignment_id: hex(i["producer_assignment_id"]),
        run_id: hex(i["run_id"]),
        run_shard: i["run_shard"],
        authority_epoch: i["authority_epoch"],
        production_scope_id: hex(i["production_scope_id"]),
        scope_sha256: hex(i["scope_sha256"]),
        source: corpus_source(i["source"])
      }
    }

    {coordinates, attribution}
  end

  defp corpus_source(nil), do: nil

  defp corpus_source(s),
    do: %EdgeSourceSpanIdentityV1{
      kind: EdgeSourceAuthorizationKind.key(s["kind"]),
      context_id: hex(s["context_id"]),
      source_scope_id: hex(s["source_scope_id"]),
      source_scope_sha256: hex(s["source_scope_sha256"])
    }

  defp signed_fixture(name) do
    signed_record(EdgeRecordV1.decode(load(name)))
  end

  defp signed_record(record) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<0x39>>, 32))

    sign = fn cap ->
      %{
        cap
        | signature:
            :crypto.sign(:eddsa, :none, CapabilitySigning.signing_bytes(cap), [private, :ed25519])
      }
    end

    record = %{
      record
      | production_capability: sign.(record.production_capability),
        source_authorization: sign_source(record.source_authorization, sign)
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    pc = record.production_capability
    keys = %{{pc.issuer_id, pc.issuer_key_id} => public}

    keys =
      case record.source_authorization do
        nil -> keys
        %{capability: sc} -> Map.put(keys, {sc.issuer_id, sc.issuer_key_id}, public)
      end

    <<millis::big-48, _::binary>> = record.event_id

    policy = %{
      trust: fn issuer, key, _purpose ->
        case Map.fetch(keys, {issuer, key}) do
          {:ok, pub} -> {:ok, pub, :valid}
          :error -> :error
        end
      end,
      now_unix_nano: millis * 1_000_000,
      active_fence: {:resolved, record.producer_context.authority_epoch},
      trust_policy_epoch: 1
    }

    {record, EdgeRecordV1.encode(record), policy}
  end

  defp sign_source(nil, _sign), do: nil
  defp sign_source(source, sign), do: %{source | capability: sign.(source.capability)}

  defp coordinates(r, raw),
    do: %{
      network_scope_id: r.network_scope_id,
      authenticated_agent_id: r.producer_context.origin_principal_id,
      lane_route_profile: r.route_profile,
      lane_traffic_class: r.traffic_class,
      spool_generation_id: uuid(25),
      sequence: 9,
      event_id: r.event_id,
      record_sha256: :crypto.hash(:sha256, raw)
    }

  defp load(name), do: File.read!(Path.join(@fixtures, name))
  defp hex(value), do: Base.decode16!(value, case: :mixed)
  defp uuid(n), do: <<0::40, 1, 0x70, n, 0x80, n, n, n, n, n, n, n>>
  defp digest(n), do: :binary.copy(<<n>>, 32)
end
