defmodule ServiceRadar.Edge.RecoveryAssignmentTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecoveryAssignment
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1

  test "the structured key preserves namespace, scope IDs and source kind independently of intervals" do
    original = span(:active, true)
    assert {:ok, key} = RecoveryAssignment.key(uuid(1), "agent01.example.com", original)

    assert key == %{
             "trust_namespace" => ["00000000000040008000000000000001", "agent01.example.com"],
             "span_identity" => [
               "00000000000040008000000000000002",
               "00000000000040008000000000000003",
               7,
               9,
               "00000000000040008000000000000004",
               String.duplicate("55", 32),
               String.duplicate("66", 32),
               [
                 1,
                 "00000000000040008000000000000005",
                 "00000000000040008000000000000006",
                 String.duplicate("77", 32)
               ],
               String.duplicate("77", 32)
             ]
           }

    assert {:ok, ^key} =
             RecoveryAssignment.key(uuid(1), "agent01.example.com", %{
               original
               | from_sequence: 90,
                 through_sequence: 120
             })

    variants = [
      {uuid(8), "agent01.example.com", original},
      {uuid(1), "agent02.example.com", original},
      {uuid(1), "agent01.example.com",
       update_identity(original, &%{&1 | production_scope_id: uuid(8)})},
      {uuid(1), "agent01.example.com",
       update_source(original, &%{&1 | source_scope_id: uuid(8)})},
      {uuid(1), "agent01.example.com",
       update_source(original, &%{&1 | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE})}
    ]

    for {scope, agent, changed} <- variants do
      assert {:ok, different} = RecoveryAssignment.key(scope, agent, changed)
      refute different == key
    end
  end

  test "classification and source presence are independent axes" do
    keys =
      for kind <- [:active, :passive], source? <- [false, true] do
        assert {:ok, key} =
                 RecoveryAssignment.key(uuid(1), "agent01.example.com", span(kind, source?))

        assert RecoveryAssignment.valid_key?(key)
        key
      end

    assert length(Enum.uniq(keys)) == 4
  end

  test "partial source, unknown fields and unattributable spans cannot select an assignment" do
    original = span(:active, true)

    bad = [
      update_source(original, &%{&1 | context_id: <<>>}),
      update_source(original, &%{&1 | source_scope_id: <<>>}),
      update_identity(original, &%{&1 | __unknown_fields__: [{77, :varint, 1}]}),
      %{original | classification: nil},
      %{original | classification: {:attributed_active, %{identity: nil}}}
    ]

    for changed <- bad do
      assert {:error, :invalid_key} =
               RecoveryAssignment.key(uuid(1), "agent01.example.com", changed)
    end
  end

  test "positive mapping resolves execution independently of the producer run" do
    {:ok, key} = RecoveryAssignment.key(uuid(1), "agent01.example.com", span(:active, true))
    value = positive()
    assert {:found, ^value} = RecoveryAssignment.selected(key, value)
    refute value["execution_id"] == Enum.at(key["span_identity"], 1)

    for change <- [
          %{"assignment_epoch" => 10},
          %{"execution_shard" => 8},
          %{"range" => %{"id" => hex(uuid(8)), "sha256" => hex(digest(0x77))}},
          %{"correlation" => %{"kind" => "execution_id", "id" => hex(uuid(8))}},
          %{"plan" => %{"id" => hex(uuid(9)), "sha256" => "invalid"}},
          %{"reason" => "standing_output_grant"}
        ] do
      assert :corrupt = RecoveryAssignment.selected(key, Map.merge(value, change))
    end
  end

  test "only an explicit negative returns not_scheduled and it cannot carry positive fields" do
    {:ok, key} = RecoveryAssignment.key(uuid(1), "agent01.example.com", span(:passive, false))

    value = %{
      "version" => 1,
      "kind" => "explicit_negative",
      "reason" => "standing_output_grant",
      "authority" => %{"producer_assignment_id" => hex(uuid(2)), "authority_epoch" => 9}
    }

    assert {:not_scheduled, ^value} = RecoveryAssignment.selected(key, value)

    for bad <- [
          nil,
          %{},
          Map.put(value, "execution_id", hex(uuid(5))),
          Map.put(value, "reason", "missing")
        ] do
      assert :corrupt = RecoveryAssignment.selected(key, bad)
    end

    {:ok, sourced_key} =
      RecoveryAssignment.key(uuid(1), "agent01.example.com", span(:passive, true))

    assert :corrupt = RecoveryAssignment.selected(sourced_key, value)
  end

  test "recovery control is source-authorized but can have an explicit negative execution mapping" do
    control =
      update_source(
        span(:passive, true),
        &%{
          &1
          | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
        }
      )

    {:ok, key} = RecoveryAssignment.key(uuid(1), "agent01.example.com", control)

    value = %{
      "version" => 1,
      "kind" => "explicit_negative",
      "reason" => "recovery_control",
      "authority" => %{"producer_assignment_id" => hex(uuid(2)), "authority_epoch" => 9}
    }

    assert {:not_scheduled, ^value} = RecoveryAssignment.selected(key, value)
  end

  defp positive do
    %{
      "version" => 1,
      "kind" => "positive",
      "execution_id" => hex(uuid(5)),
      "plan" => %{"id" => hex(uuid(9)), "sha256" => hex(digest(0x88))},
      "range" => %{"id" => hex(uuid(6)), "sha256" => hex(digest(0x77))},
      "execution_shard" => 7,
      "assignment_epoch" => 9,
      "correlation" => %{"kind" => "execution_id", "id" => hex(uuid(5))}
    }
  end

  defp span(kind, source?) do
    id = %EdgeAttributedSpanIdentityV1{
      producer_assignment_id: uuid(2),
      run_id: uuid(3),
      run_shard: 7,
      authority_epoch: 9,
      production_scope_id: uuid(4),
      scope_sha256: digest(0x55),
      contract_bundle_sha256: digest(0x66),
      source:
        if(source?,
          do: %EdgeSourceSpanIdentityV1{
            kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
            context_id: uuid(5),
            source_scope_id: uuid(6),
            source_scope_sha256: digest(0x77)
          }
        )
    }

    classification =
      case kind do
        :active ->
          {:attributed_active, %EdgeAttributedActiveV1{identity: id, range_sha256: digest(0x77)}}

        :passive ->
          {:attributed_passive, %EdgeAttributedPassiveV1{identity: id}}
      end

    %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification: classification
    }
  end

  defp update_identity(%{classification: {kind, body}} = span, update),
    do: %{span | classification: {kind, %{body | identity: update.(body.identity)}}}

  defp update_source(span, update), do: update_identity(span, &%{&1 | source: update.(&1.source)})

  defp uuid(n), do: <<0::48, 4::4, 0::12, 2::2, n::62>>
  defp digest(n), do: :binary.copy(<<n>>, 32)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
