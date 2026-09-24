defmodule ServiceRadar.Edge.FamilyCorpusTest do
  @moduledoc """
  The SHARED FRAMING-FAMILY corpus (task 1.5-g): which payload family may enter which TYPED
  ingress.

  ## The decision this consumes

  There is NO global family-to-contract mapping and no registry-wide contract-to-family table --
  the exact output contract selects the semantic validator and the projector. What is frozen is a
  family-to-TYPED-ENTRYPOINT invariant, and `payload_family` is therefore an immutable FRAMING and
  LIFECYCLE discriminator: not decorative metadata, not authorization, not a routing key.

  ## Why this runtime checks it before decoding

  `SweepCorrelate.ingest_own_payload/1` decodes `record.payload` as a `SweepObservationBatchV1`
  regardless of what the record declares, because protobuf bytes are not intrinsically
  type-tagged. Checking the family first is what stops the body being parsed under a schema the
  declared family says not to use.

  The stage equivalence with Go is per BOUNDARY, not per call sequence:

      Go:     signed whole-record validation -> contract dispatch -> framing family -> extract/decode
      Elixir: those two are documented PRECONDITIONS -> framing family -> local payload checks/decode

  ## What this suite does NOT claim

  Lifecycle and recovery parity, which task 1.5-m owns. This runtime has no lifecycle record
  validator, and its recovery check reads source-authority kind rather than `payload_family`, so
  it does not refuse a recovery-family/ordinary-route mismatch. 1.6-c and 1.6-d are NOT the
  owners: 1.6-c is scoped to `ValidateSweepExecutionEvent` and excludes `ValidateLifecycleRecord`,
  and 1.6-d supplies the signed recovery-control boundary that 1.5-m then attaches the framing
  rule to. Manufacturing either here would prove only that a corpus helper can refuse its own
  inputs.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SemanticDigest
  alias ServiceRadar.Edge.SemanticValidate
  alias ServiceRadar.Edge.SweepCorrelate
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "family_corpus.txt")
  @external_resource @manifest

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

  defp load(name), do: testdata_dir() |> Path.join(name) |> File.read!()

  defp rows do
    testdata_dir()
    |> Path.join("family_corpus.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [entrypoint, family, file, typed, generic] = String.split(line)
      %{entrypoint: entrypoint, family: family, file: file, typed: typed, generic: generic}
    end)
  end

  # The declared non-recovery families, derived from the GENERATED enum rather than restated.
  # UNSPECIFIED is not a declared family; RECOVERY_CONTROL_V1 is excluded because its lane rule
  # preempts generic admission, so a row for it would be refused by a different rule.
  defp declared_families do
    Serviceradar.Edge.V1.EdgeRecordPayloadFamily.mapping()
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.reject(
      &(&1 in [
          "EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED",
          "EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1"
        ])
    )
    |> MapSet.new(fn name ->
      name |> String.replace_prefix("EDGE_RECORD_PAYLOAD_FAMILY_", "") |> String.downcase()
    end)
  end

  # The manifest's short name back to the generated atom, so the assertion names the record's
  # own family rather than accepting whatever the runtime chose to report.
  defp family_atom(short),
    do: String.to_existing_atom("EDGE_RECORD_PAYLOAD_FAMILY_" <> String.upcase(short))

  defp accepted?(:ok), do: true
  defp accepted?({:ok, _}), do: true
  defp accepted?(_), do: false

  test "the manifest covers exactly the declared non-recovery families" do
    declared = declared_families()

    refute Enum.empty?(declared),
           "the declared-family walk found nothing; the comparison below would be vacuous"

    assert MapSet.new(rows(), & &1.family) == declared
  end

  test "every row is a sweep row, named once, with a file of its own" do
    rows = rows()

    # No SILENT SKIP. The typed test below iterates rows; if an unknown entrypoint appeared it
    # would be filtered out and the suite would stay green having executed less than it claims.
    assert Enum.all?(rows, &(&1.entrypoint == "sweep")),
           "an entrypoint other than sweep appeared; this suite would skip it silently"

    families = Enum.map(rows, & &1.family)
    files = Enum.map(rows, & &1.file)

    assert length(families) == length(Enum.uniq(families)), "a family is listed twice"
    assert length(files) == length(Enum.uniq(files)), "a fixture is named by two rows"
  end

  test "the typed sweep ingress admits only the framing family, and refuses for THAT reason" do
    for row <- rows() do
      record = EdgeRecordV1.decode(load(row.file))
      verdict = SweepCorrelate.ingest_own_payload(record)

      case row.typed do
        "accept" ->
          assert accepted?(verdict),
                 "#{row.family}: Go admits this at the typed sweep ingress; this runtime refused " <>
                   "it -- #{inspect(verdict, limit: 3)}"

        "refuse" ->
          # THE EXACT VALUE, not a wildcard. A stale signature, a body defect or a failed join
          # would otherwise masquerade as family evidence -- and a wildcard would also pass on a
          # constant audit value that ignored the record entirely.
          expected = family_atom(row.family)

          assert {:error, {:payload, {:framing_family, ^expected}}} = verdict

          # And the SECOND typed ingress refuses the same bytes for the same reason: it decodes
          # the payload as a sweep batch too, so leaving it ungated would be a live bypass.
          assert {:error, {:payload, {:framing_family, ^expected}}} =
                   SweepCorrelate.correlate_own_payload(record)
      end
    end
  end

  test "the GENERIC validator stays permissive on every row" do
    # The generic column is part of the contract: it has no entry-point context and cannot choose
    # among the declared families. Verifying it here is what stops a future change making it
    # strict and calling that a fix -- and the column would otherwise be Go-asserted only.
    for row <- rows() do
      record = EdgeRecordV1.decode(load(row.file))

      assert row.generic == "accept",
             "#{row.family}: the manifest records a generic refusal, which this rule does not permit"

      assert SemanticValidate.validate_record(record) == :ok,
             "#{row.family}: the generic validator refused a record Go admits"
    end
  end

  test "a family that is not an enum value at all is a PRECONDITION failure, not a framing one" do
    # These functions accept `term()` and must stay TOTAL. A generated struct is a map, so a
    # hand-built record can hold any term in `payload_family`; that is a shape this relation
    # cannot read. Classifying it as `:malformed_record` is what keeps
    # `{:framing_family, atom() | integer()}` a TRUE statement about the public result type --
    # widening the tuple to `term()` would make it promise less instead.
    record = EdgeRecordV1.decode(load(Enum.at(rows(), 0).file))

    for bogus <- [%{}, [1, 2], "snapshot", {:a, :b}, 1.5] do
      assert {:error, {:precondition, :malformed_record}} =
               SweepCorrelate.ingest_own_payload(%{record | payload_family: bogus})

      assert {:error, {:precondition, :malformed_record}} =
               SweepCorrelate.correlate_own_payload(%{record | payload_family: bogus})
    end
  end

  test "a wrong family stops at the framing gate, before the payload is decoded" do
    # The ONE precedence control this task owns. A record whose family is wrong AND whose payload
    # cannot decode must stop at the gate; stopping at the decoder would mean the body was parsed
    # under a schema the declared family says not to use.
    #
    # Not a general reason-order matrix: ordering among other simultaneous precondition
    # violations is outside this boundary.
    row = Enum.find(rows(), &(&1.typed == "refuse"))
    record = EdgeRecordV1.decode(load(row.file))
    payload = <<0xFF, 0xFF, 0xFF, 0xFF>>

    # The digest and sizes are REBOUND to the new payload. Leaving them stale would make
    # `payload_digest/2` a second competing rejection, and the control could pass while the
    # framing gate did nothing.
    broken =
      then(
        %{
          record
          | payload: payload,
            payload_sha256: :crypto.hash(:sha256, payload),
            encoded_size: byte_size(payload),
            uncompressed_size: byte_size(payload)
        },
        &%{&1 | semantic_envelope_sha256: SemanticDigest.compute(&1)}
      )

    # RESEALED. These functions document a whole-record-validated precondition, and an
    # envelope digest left over from the original payload would violate it -- the control
    # would still pass, but on a record no authenticated boundary would have handed them.
    assert {:error, {:payload, {:framing_family, _}}} =
             SweepCorrelate.ingest_own_payload(broken)

    assert {:error, {:payload, {:framing_family, _}}} =
             SweepCorrelate.correlate_own_payload(broken)
  end
end
