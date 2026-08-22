defmodule ServiceRadar.Edge.RecoveryControlBoundsTest do
  @moduledoc """
  Task 1.6-d: the THREE BOUND SITES task 1.5-h delegates here, four controls each.

  Each is reachable only through the SIGNED recovery-control boundary, which is why 1.5-h could
  not close them in this runtime and delegated them to the subtask that creates the boundary:

    * the tombstone's `reason`, bounded 1..256
    * the tombstone's DECLARED `manifest_page_count`, bounded 1..1024 -- a scalar committed by
      the scope digest, NOT the supplied page list `tombstone/2` reconciles
    * `classification_spans` on a single page, bounded 1..256, at the isolation site rather than
      the chain walk

  ## Four controls, not two

  Zero REFUSED and one ACCEPTED are both required. A frozen minimum of 1 needs both, because a
  peer tightened to reject length 1 would satisfy the zero row unchanged and look correct. The
  same holds at the ceiling: at-limit ACCEPTED and one-over REFUSED together are what pin the
  boundary to 256 rather than to "somewhere near 256".

  ## Why the records are built rather than committed

  These vary the BODY, so they cannot reuse a committed record's signature. Each control seeds
  from the committed recovery-control record -- a known-valid shape this runtime did not invent
  -- swaps in the body under test, and re-signs both capabilities with a keypair generated here.
  The signed path therefore runs for real: a control that failed verification would fail with
  `:signature` and not with the bound's refusal, which is what the assertions distinguish.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.RecoveryValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  @max_reason_bytes 256
  @max_manifest_pages 1024
  @max_spans_per_page 256

  defp testdata_dir do
    cond do
      File.dir?(@testdata) ->
        @testdata

      dir = System.get_env("TEST_SRCDIR") ->
        [System.get_env("TEST_WORKSPACE"), "_main"]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata"]))
        |> Enum.find(&File.dir?/1)
        |> case do
          nil -> flunk("shared fixture directory not found under #{@testdata} or TEST_SRCDIR")
          p -> p
        end

      true ->
        flunk("shared fixture directory not found under #{@testdata}")
    end
  end

  defp committed(name), do: File.read!(Path.join(testdata_dir(), name))

  defp base_record(name), do: EdgeRecordV1.decode(committed(name))

  defp body_of(name) do
    r = base_record(name)
    %EdgeRecoveryControlPayloadV1{body: body} = EdgeRecoveryControlPayloadV1.decode(r.payload)
    body
  end

  # Re-seals a record around a new control body and re-signs both capabilities, so the ONLY
  # difference from the committed shape is the body under test. Ordering matters: the source
  # claims are rescoped to the new body, the capabilities are signed over those claims, and the
  # semantic envelope is sealed LAST so it covers the claims the record ships with.
  defp signed_record(base_name, body, claimed_scope \\ nil) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    base = base_record(base_name)
    payload = EdgeRecoveryControlPayloadV1.encode(%EdgeRecoveryControlPayloadV1{body: body})
    {rid, true_scope} = scope_of(body)
    scope = claimed_scope || true_scope

    sa = base.source_authorization
    {:source, claims} = sa.capability.claims

    src_cap =
      sign(
        %{
          sa.capability
          | claims: {:source, %{claims | context_id: rid, scope_id: rid, scope_sha256: scope}}
        },
        priv
      )

    record = %{
      base
      | payload: payload,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        payload_sha256: :crypto.hash(:sha256, payload),
        production_capability: sign(base.production_capability, priv),
        source_authorization: %{
          sa
          | capability: src_cap,
            context_id: rid,
            scope_id: rid,
            scope_sha256: scope
        }
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}

    {record, policy_for(record, pub)}
  end

  defp scope_of({:tombstone, t}), do: {t.recovery_id, HashGrammar.tombstone_scope_digest(t)}

  defp scope_of({:manifest_page, p}),
    do: {p.recovery_id, HashGrammar.manifest_page_scope_digest(p)}

  defp sign(cap, priv) do
    %{
      cap
      | signature:
          :crypto.sign(:eddsa, :none, CapabilitySigning.signing_bytes(cap), [priv, :ed25519])
    }
  end

  defp policy_for(record, pub) do
    pc = record.production_capability
    src = record.source_authorization.capability

    keys = %{
      {pc.issuer_id, pc.issuer_key_id} => pub,
      {src.issuer_id, src.issuer_key_id} => pub
    }

    %{
      trust: fn issuer_id, key_id, _purpose ->
        case Map.fetch(keys, {issuer_id, key_id}) do
          {:ok, key} -> {:ok, key, :valid}
          :error -> :error
        end
      end,
      now_unix_nano: uuidv7_millis(record.event_id) * 1_000_000,
      active_fence: {:resolved, record.producer_context.authority_epoch},
      trust_policy_epoch: 1
    }
  end

  defp uuidv7_millis(<<millis::big-48, _rest::binary-size(10)>>), do: millis

  # Runs the FULL signed boundary, and separates the two ways a control can fail. A refusal from
  # the signed path would mean the control is measuring signature construction rather than the
  # bound, so it is flagged distinctly rather than counted as the expected refusal.
  defp admit(base_name, body) do
    {record, policy} = signed_record(base_name, body)

    case RecoveryValidate.record_signed(record, policy) do
      :ok ->
        RecoveryValidate.recovery_control(record, record.output_contract, policy)

      {:error, reason} ->
        flunk(
          "the constructed record failed the SIGNED path with #{inspect(reason)}, so this " <>
            "control would measure signing rather than the bound"
        )
    end
  end

  # Varies the FRAMING coordinates and the raw payload, reusing the same signing machinery as
  # signed_record/3. Nothing new is committed: the shape comes from the same recovery record the
  # corpus rows use, and only the fields under test differ.
  defp framed(opts) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    base = base_record("version_tombstone_scope_ok.bin")
    payload = Keyword.get(opts, :payload, base.payload)

    record = %{
      base
      | payload_family: Keyword.get(opts, :family, base.payload_family),
        route_profile: Keyword.get(opts, :route, base.route_profile),
        payload: payload,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        payload_sha256: :crypto.hash(:sha256, payload),
        production_capability: sign(base.production_capability, priv)
    }

    sa = record.source_authorization

    record = %{
      record
      | source_authorization: %{
          sa
          | capability: sign(sa.capability, priv),
            kind: Keyword.get(opts, :source_kind, sa.kind)
        }
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}

    {record, policy_for(record, pub)}
  end

  defp admit_framed(opts) do
    {record, policy} = framed(opts)

    case RecoveryValidate.record_signed(record, policy) do
      :ok ->
        RecoveryValidate.recovery_control(record, record.output_contract, policy)

      {:error, reason} ->
        flunk(
          "the constructed record failed the SIGNED path with #{inspect(reason)}, so this " <>
            "control would measure signing rather than the framing rule"
        )
    end
  end

  defp tombstone_with(fields) do
    {:tombstone, t} = body_of("version_tombstone_scope_ok.bin")
    {:tombstone, struct!(t, fields)}
  end

  defp page_with_spans(n) do
    {:manifest_page, p} = body_of("version_manifest_page_scope_ok.bin")
    [span | _] = p.classification_spans

    spans =
      for i <- 1..n//1 do
        %{span | from_sequence: i * 10, through_sequence: i * 10 + 1}
      end

    page = %{p | classification_spans: spans}
    {:manifest_page, %{page | page_sha256: HashGrammar.manifest_page_digest(page)}}
  end

  describe "the tombstone reason is bounded 1..#{@max_reason_bytes}" do
    test "length 0 is REFUSED" do
      assert {:error, :tombstone_mismatch} =
               admit("version_tombstone_scope_ok.bin", tombstone_with(reason: ""))
    end

    test "length 1 is ACCEPTED" do
      assert :ok = admit("version_tombstone_scope_ok.bin", tombstone_with(reason: "x"))
    end

    test "the ceiling is ACCEPTED" do
      at = String.duplicate("x", @max_reason_bytes)
      assert :ok = admit("version_tombstone_scope_ok.bin", tombstone_with(reason: at))
    end

    test "one over the ceiling is REFUSED" do
      over = String.duplicate("x", @max_reason_bytes + 1)

      assert {:error, :tombstone_mismatch} =
               admit("version_tombstone_scope_ok.bin", tombstone_with(reason: over))
    end
  end

  describe "the tombstone's DECLARED manifest_page_count is bounded 1..#{@max_manifest_pages}" do
    test "count 0 is REFUSED" do
      assert {:error, :tombstone_mismatch} =
               admit("version_tombstone_scope_ok.bin", tombstone_with(manifest_page_count: 0))
    end

    test "count 1 is ACCEPTED" do
      assert :ok = admit("version_tombstone_scope_ok.bin", tombstone_with(manifest_page_count: 1))
    end

    test "the ceiling is ACCEPTED" do
      assert :ok =
               admit(
                 "version_tombstone_scope_ok.bin",
                 tombstone_with(manifest_page_count: @max_manifest_pages)
               )
    end

    test "one over the ceiling is REFUSED" do
      assert {:error, :tombstone_mismatch} =
               admit(
                 "version_tombstone_scope_ok.bin",
                 tombstone_with(manifest_page_count: @max_manifest_pages + 1)
               )
    end
  end

  describe "a single page's classification_spans are bounded 1..#{@max_spans_per_page}" do
    # THE EXACT REASON, not merely a refusal. The local arm is classed `retags`: with the span
    # bound removed the boundary still refuses these bodies, under the span-body reason instead.
    # Asserting only that a refusal occurred would pass with the bound deleted.
    test "0 spans is REFUSED as a BOUNDS fault" do
      assert {:error, :manifest_bounds} =
               admit("version_manifest_page_scope_ok.bin", page_with_spans(0))
    end

    test "1 span is ACCEPTED" do
      assert :ok = admit("version_manifest_page_scope_ok.bin", page_with_spans(1))
    end

    test "the ceiling is ACCEPTED" do
      assert :ok =
               admit("version_manifest_page_scope_ok.bin", page_with_spans(@max_spans_per_page))
    end

    test "one over the ceiling is REFUSED as a BOUNDS fault" do
      assert {:error, :manifest_bounds} =
               admit(
                 "version_manifest_page_scope_ok.bin",
                 page_with_spans(@max_spans_per_page + 1)
               )
    end
  end

  describe "the boundary's ORDER is part of the rule" do
    # THE STAGE ORDER, NOT MERELY THE PRESENCE OF BOTH STAGES.
    #
    # Every other test here calls record_signed/2 itself before recovery_control/3 -- the corpus
    # rows do it as their ordering gate, and admit/2 does it to separate a signing failure from a
    # bound's refusal. That is deliberate, and it leaves a hole: a boundary that quietly stopped
    # verifying would still satisfy all of them, because they had already verified.
    #
    # So this drives recovery_control/3 ALONE, with a record carrying BOTH faults at once. If the
    # boundary compared the scope first, the refusal would be :tombstone_mismatch. It reports the
    # signature fault, which is what pins the order -- and is why a stale signature cannot
    # masquerade as ceiling evidence.
    test "a stale signature is refused BEFORE the scope is compared" do
      {record, policy} =
        signed_record("version_tombstone_scope_ok.bin", tombstone_with(reason: "x"))

      sa = record.source_authorization
      {:source, claims} = sa.capability.claims

      tampered = %{
        record
        | source_authorization: %{
            sa
            | capability: %{
                sa.capability
                | claims: {:source, %{claims | scope_sha256: :binary.copy(<<0xEE>>, 32)}}
              }
          }
      }

      # Resealed so the STRUCTURAL validator still passes: the envelope covers the tampered
      # claims, and only the signature is stale. Without this the record would fail earlier, on
      # the envelope digest, and prove nothing about the ordering.
      tampered = %{tampered | semantic_envelope_sha256: SemanticDigest.compute(tampered)}

      assert {:error, :signature} =
               RecoveryValidate.recovery_control(tampered, tampered.output_contract, policy)
    end

    # The complement, with ONE fault: correctly signed, and claiming a scope that does not fix
    # this operation. Refused at the comparison. Together the two pin both stages and their order,
    # one fault each, reported distinctly.
    test "a correctly signed record claiming the wrong scope is refused at the comparison" do
      {record, policy} =
        signed_record(
          "version_tombstone_scope_ok.bin",
          tombstone_with(reason: "x"),
          :binary.copy(<<0xEE>>, 32)
        )

      assert :ok = RecoveryValidate.record_signed(record, policy),
             "the record must be correctly signed, or this would measure the signature instead"

      assert {:error, :tombstone_mismatch} =
               RecoveryValidate.recovery_control(record, record.output_contract, policy)
    end

    # THE UNSIGNED OUTER ECHO IS NOT WHAT AUTHORIZES. EdgeSourceAuthorizationV1 carries
    # scope_sha256 beside the capability, and the comparison reads the SIGNED claim instead. A
    # boundary that read the outer field would let anyone who can rewrite an unsigned envelope
    # field satisfy the comparison, so this pins which of the two values is load-bearing.
    test "the comparison reads the signed claim, not the outer echo" do
      {record, policy} =
        signed_record("version_tombstone_scope_ok.bin", tombstone_with(reason: "x"))

      sa = record.source_authorization

      echo_only = %{
        record
        | source_authorization: %{sa | scope_sha256: :binary.copy(<<0xEE>>, 32)}
      }

      echo_only = %{echo_only | semantic_envelope_sha256: SemanticDigest.compute(echo_only)}

      assert :ok =
               RecoveryValidate.recovery_control(
                 echo_only,
                 echo_only.output_contract,
                 policy
               )
    end
  end

  describe "the framing family is bound to THIS typed ingress (task 1.5-m)" do
    # The requirement binds each typed ingress to exactly one family, so every OTHER declared
    # family must be refused here. Driven from the generated enum rather than a hand-written
    # list: a family added to the schema is then refused by construction, not by remembering.
    # Derived from the GENERATED enum rather than restated, the same way the family corpus does
    # it: a family added to the schema is then refused here by construction, not by remembering.
    @other_families Serviceradar.Edge.V1.EdgeRecordPayloadFamily.mapping()
                    |> Map.keys()
                    |> Enum.reject(
                      &(&1 in [
                          :EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED,
                          :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
                        ])
                    )

    test "every other declared family is refused" do
      assert @other_families != [], "the enum yielded no other families to refuse"

      for family <- @other_families do
        assert {:error, :recovery_lane} = admit_framed(family: family),
               "family #{family} entered the recovery ingress"
      end
    end

    test "the recovery family on an ordinary route is refused" do
      assert {:error, :recovery_lane} =
               admit_framed(route: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1)
    end

    # The third arm of the reserved lane: a recovery payload on the recovery route, carrying
    # authority that is not recovery authority. The mutation battery found this arm UNPINNED --
    # removing it left every other test green, because nothing here varied the source kind.
    test "the recovery lane without recovery authority is refused" do
      assert {:error, :recovery_lane} =
               admit_framed(source_kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP)
    end

    # THE PRECEDENCE CONTROL. A record whose family is wrong AND whose payload is malformed must
    # be refused at the FRAMING boundary -- which is what demonstrates the typed decode was never
    # entered. The pair is the proof: the same malformed bytes under the CORRECT family reach the
    # decoder and fail there, so the two refusals distinguish which gate stopped the record.
    test "a wrong family with a malformed payload stops at the framing gate" do
      malformed = <<0xFF, 0xFF, 0xFF, 0xFF>>

      assert {:error, :payload_decode} =
               admit_framed(payload: malformed),
             "the malformed payload must reach the decoder when the family is correct, or the " <>
               "precedence control proves nothing"

      assert {:error, :recovery_lane} =
               admit_framed(
                 family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
                 payload: malformed
               )
    end
  end
end
