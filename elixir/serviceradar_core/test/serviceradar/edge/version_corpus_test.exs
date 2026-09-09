defmodule ServiceRadar.Edge.VersionCorpusTest do
  @moduledoc """
  The SHARED VERSION corpus (tasks 1.5-b, 1.6-a, 1.6-b): Go's bytes, Elixir's verdict, over one
  exhaustive Appendix A object inventory.

  Every row commits a CONTROL and an ALTERED-VERSION artifact. Class A objects decode a version
  from their input and carry an unsupported one; Class B objects carry the digest or identifier a
  peer running the NEXT grammar version would emit. This suite runs both through the same
  production verifier this runtime uses, and requires accept then refuse.

  ## The inventory is asserted, not counted

  `@expected_inventory` is hand-written. It is NOT derived from the manifest, because a manifest
  regenerated from a generator that lost an object is perfectly self-consistent -- every count
  taken from it would agree with itself while "exhaustive" quietly meant one fewer object. The
  membership and class checks come first; the count is informational and comes last.

  All nineteen objects now have both runtime verifiers. The empty exemption set is asserted.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.CompiledAssignmentValidate
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecoveryValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.CompiledSweepAssignmentV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "version_corpus.txt")
  @external_resource @manifest

  # The hand-written Appendix A inventory: object -> proof class.
  @expected_inventory %{
    "capability" => "A",
    "manifest_page" => "A",
    "tombstone" => "A",
    "plan_header" => "A",
    "plan_page" => "A",
    "compiled_assignment" => "A",
    "mtr_completion" => "A",
    "transport_provenance" => "A",
    "semantic_envelope" => "B",
    "manifest_root" => "B",
    "plan_root" => "B",
    "range_digest" => "B",
    "tombstone_scope" => "B",
    "manifest_page_scope" => "B",
    "resolved_scope" => "B",
    "nats_msgid_edge" => "B",
    "nats_msgid_service" => "B",
    "delivery_id_edge" => "B",
    "delivery_id_service" => "B"
  }

  # The CLOSED set of members no Elixir consumer enforces, and the reason parent task 1.6 stays
  # open. Membership is a CONTRACT statement: an object belongs here only while this runtime has
  # no production verifier that trusts the value -- never because writing one is inconvenient,
  # and never as a standing exemption. The set is asserted exactly, so it cannot drift in either
  # direction without a test failing.
  @expected_go_only MapSet.new()

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

  # Resolves `file` or `file#row`, where a row is looked up by name in a tab-separated vector
  # file. The nineteenth object reuses an artifact another generator owns; naming it is not
  # enough, so it is resolved and executed like every other row.
  defp artifact(ref) do
    [file | rest] = String.split(ref, "#", parts: 2)
    raw = testdata_dir() |> Path.join(file) |> File.read!()

    case rest do
      [] ->
        raw

      [row] ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "\t", parts: 2) do
            [^row, value] -> value
            _ -> nil
          end
        end)
        |> case do
          nil -> flunk("#{file} has no row named #{row}")
          value -> value
        end
    end
  end

  defp rows do
    testdata_dir()
    |> Path.join("version_corpus.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Map.new(fn line ->
      [object, class, ok, alt, peer, runtimes] = String.split(line)
      {object, %{class: class, ok: ok, alt: alt, peer: peer, runtimes: runtimes}}
    end)
  end

  # A length-delimited run of messages: the framing Go uses to commit a multi-message peer as ONE
  # file, so the peer input is a committed artifact rather than a naming convention.
  defp unframe(<<>>), do: []

  defp unframe(bin) do
    {len, rest} = take_varint(bin)
    <<msg::binary-size(len), tail::binary>> = rest
    [msg | unframe(tail)]
  end

  defp take_varint(bin), do: take_varint(bin, 0, 0)

  defp take_varint(<<1::1, chunk::7, rest::binary>>, shift, acc),
    do: take_varint(rest, shift + 7, Bitwise.bor(acc, Bitwise.bsl(chunk, shift)))

  defp take_varint(<<0::1, chunk::7, rest::binary>>, shift, acc),
    do: {Bitwise.bor(acc, Bitwise.bsl(chunk, shift)), rest}

  # Rebuilt from the COMMITTED public key, so the peer file authorises the record rather than a
  # key the generator happens to still hold. One key serves both capabilities; they carry
  # different issuer ids, which is what makes the two lookups distinct.
  defp scope_policy_for(record, pub) do
    assert byte_size(pub) == 32, "committed issuer key is #{byte_size(pub)} bytes, want 32"

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

  # ---- the per-object verifiers, each this runtime's PRODUCTION boundary -------------------

  defp verify("mtr_completion", artifact, _peer) do
    artifact
    |> Serviceradar.Edge.V1.SweepExecutionEventV1.decode()
    |> ServiceRadar.Edge.LifecycleValidate.validate()
  end

  defp verify("capability", artifact, _peer) do
    r = EdgeRecordV1.decode(artifact)
    CapabilitySigning.validate(r.production_capability, :production)
  end

  defp verify("semantic_envelope", artifact, _peer) do
    r = EdgeRecordV1.decode(artifact)
    equal_digest(SemanticDigest.compute(r), r.semantic_envelope_sha256)
  end

  defp verify("manifest_page", artifact, _peer) do
    RecoveryValidate.manifest_chain([EdgeLossManifestPageV1.decode(artifact)], nil)
  end

  defp verify(object, artifact, peer) when object in ["tombstone", "manifest_root"] do
    pages = Enum.map(unframe(peer), &EdgeLossManifestPageV1.decode/1)
    RecoveryValidate.tombstone(SpoolLossTombstoneV1.decode(artifact), pages)
  end

  defp verify(object, artifact, peer) when object in ["plan_header", "plan_root"] do
    pages = Enum.map(unframe(peer), &ScheduledPlanPageV1.decode/1)
    PlanValidate.validate(ScheduledPlanHeaderV1.decode(artifact), pages)
  end

  defp verify(object, artifact, peer) when object in ["plan_page", "range_digest"] do
    pages = Enum.map(unframe(artifact), &ScheduledPlanPageV1.decode/1)
    header = ScheduledPlanHeaderV1.decode(peer)
    # The committed header roots the CONTROL pages; re-root a copy over whatever arrives so the
    # row tests the page, not the root.
    rerooted = %{header | plan_root_sha256: HashGrammar.plan_root(pages)}
    rerooted = %{rerooted | execution_plan_sha256: HashGrammar.plan_header_digest(rerooted)}

    PlanValidate.validate(rerooted, pages)
  end

  # The three recovery SCOPE transcripts, through the SIGNED boundary rather than a digest
  # recomputation. Task 1.6-d. The committed public key is what authorises the record here: the
  # generator keeps the private half, so this runtime verifies exactly what a consumer would.
  defp verify(object, artifact, peer)
       when object in ["tombstone_scope", "manifest_page_scope", "resolved_scope"] do
    record = EdgeRecordV1.decode(artifact)
    policy = scope_policy_for(record, peer)

    # THE ORDERING GATE. Both records -- control AND altered -- must clear signature and trust.
    # The altered one differs ONLY in the claimed scope digest, so if the signed path refused it
    # this row would be reporting something other than the scope comparison, and the refusal
    # below would be evidence for the wrong rule. That is a hard failure, not the row's expected
    # refusal.
    case RecoveryValidate.record_signed(record, policy) do
      :ok ->
        :ok

      {:error, reason} ->
        flunk(
          "#{object}: the signed path must accept BOTH the control and the altered record; " <>
            "this one failed with #{inspect(reason)}, so the row would prove the wrong rule"
        )
    end

    RecoveryValidate.recovery_control(record, record.output_contract, policy)
  end

  defp verify("compiled_assignment", artifact, _peer) do
    CompiledAssignmentValidate.validate(CompiledSweepAssignmentV1.decode(artifact))
  end

  defp verify("transport_provenance", artifact, _peer) do
    case PublicationIdentity.decode_transport_provenance(artifact) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify(object, artifact, _peer) when object in ["nats_msgid_edge", "nats_msgid_service"] do
    equal_identity(publication_identity(object), artifact)
  end

  defp verify(object, artifact, _peer)
       when object in ["delivery_id_edge", "delivery_id_service"] do
    equal_identity(publication_identity(object), artifact)
  end

  # THE SLOT INPUTS Go authored these identifiers from. Restated here, as the existing
  # cross-language golden suite already restates them: if they ever drift, the CONTROL row fails
  # loudly rather than the corpus quietly comparing two different things.
  defp edge_slot,
    do: %{
      network_scope_id: stable_uuid(0xD0),
      authenticated_agent_id: "agent-corpus",
      spool_id: stable_uuid(0xD1),
      sequence: 7
    }

  defp service_slot,
    do: %{
      network_scope_id: stable_uuid(0xD2),
      authenticated_service_id: "svc-corpus",
      publication_lane_id: stable_uuid(0xD3),
      publication_sequence: 9
    }

  defp publication_identity("nats_msgid_edge"),
    do: PublicationIdentity.nats_msg_id(edge_slot(), d32(0xD4), d32(0xD5))

  defp publication_identity("nats_msgid_service"),
    do: PublicationIdentity.service_nats_msg_id(service_slot(), d32(0xD6), d32(0xD7))

  defp publication_identity("delivery_id_edge"), do: PublicationIdentity.delivery_id(edge_slot())

  defp publication_identity("delivery_id_service"),
    do: PublicationIdentity.service_delivery_id(service_slot())

  defp equal_identity({:ok, computed}, carried) when computed == carried, do: :ok
  defp equal_identity({:ok, _computed}, _carried), do: {:error, :identity_mismatch}
  defp equal_identity({:error, reason}, _carried), do: {:error, reason}

  # ACCEPTANCE, normalised. These validators do not share a success shape -- PlanValidate
  # returns {:ok, index}, RecoveryValidate returns :ok -- and the cross-runtime contract is
  # accept versus refuse, not which success tuple a module happens to use.
  defp accepted?(:ok), do: true
  defp accepted?({:ok, _}), do: true
  defp accepted?(_), do: false

  defp equal_digest(a, a), do: :ok
  defp equal_digest(_a, _b), do: {:error, :digest_mismatch}

  # Go's stableUUID, byte for byte: a 48-bit real timestamp, the v7/variant nibbles at bytes 6
  # and 8, and the seed everywhere else. Restated here as the existing cross-language golden
  # suite restates its slots -- and a drift cannot pass silently, because the CONTROL row is
  # compared against Go's committed identifier.
  @bench_observed_unix_nano 1_700_000_300_000_000_000

  defp stable_uuid(seed) do
    ms = div(@bench_observed_unix_nano, 1_000_000)

    <<ms::48, 0x70, seed, 0x80, seed, seed, seed, seed, seed, seed, seed>>
  end

  # Go's d32: a 32-byte ramp starting at `tag`, NOT a repeated byte.
  defp d32(tag), do: for(i <- 0..31, into: <<>>, do: <<Bitwise.band(tag + i, 0xFF)>>)

  # ---- the gates ---------------------------------------------------------------------------

  describe "the inventory is exhaustive, and asserted rather than counted" do
    test "every expected object appears exactly once, with its class" do
      manifest = rows()

      for {object, class} <- @expected_inventory do
        row = Map.get(manifest, object)

        assert row, "inventory object #{object} is ABSENT from the manifest"
        assert row.class == class, "#{object}: manifest class #{row.class}, expected #{class}"
      end

      for {object, _row} <- manifest do
        assert Map.has_key?(@expected_inventory, object),
               "manifest carries #{object}, which is not in the inventory"
      end
    end

    test "the go_only set is exactly the one member with no Elixir boundary" do
      go_only =
        rows()
        |> Enum.filter(fn {_object, row} -> row.runtimes == "go_only" end)
        |> MapSet.new(fn {object, _row} -> object end)

      assert go_only == @expected_go_only,
             "the go_only set moved; a member gaining or losing an Elixir consumer is a " <>
               "contract change, not a bookkeeping one"

      # Each is NAMED, so the coverage gap is visible in the suite rather than being an absence.
      for object <- @expected_go_only do
        assert Map.get(rows(), object).runtimes == "go_only"
      end
    end

    test "the derived count agrees, informationally" do
      by_class = Enum.frequencies_by(@expected_inventory, fn {_o, c} -> c end)

      assert map_size(@expected_inventory) == 19
      assert by_class == %{"A" => 8, "B" => 11}
    end
  end

  describe "every shared row: the control is accepted and the altered artifact refused" do
    test "all 19 rows this runtime enforces" do
      enforced = Enum.reject(rows(), fn {_o, row} -> row.runtimes == "go_only" end)

      assert length(enforced) == 19

      for {object, row} <- enforced do
        peer = if row.peer == "-", do: nil, else: artifact(row.peer)

        assert accepted?(verify(object, artifact(row.ok), peer)),
               "#{object}: the committed CONTROL was refused -- " <>
                 inspect(verify(object, artifact(row.ok), peer), limit: 3)

        refute accepted?(verify(object, artifact(row.alt), peer)),
               "#{object}: the committed ALTERED-VERSION artifact was ACCEPTED"
      end
    end
  end
end
