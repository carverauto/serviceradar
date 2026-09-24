defmodule ServiceRadar.Edge.WireDecode do
  @moduledoc """
  Total protobuf-decode boundary for edge wire messages.

  The generated `protobuf-elixir` decoders are NOT total: a protobuf-VALID message that Go accepts
  and retains -- an unmapped/negative enum value (e.g. `lane_open.traffic_class = -1`) or malformed
  wire bytes -- makes `Mod.decode/1` RAISE. A raising decode on a durable-record consumer is a
  crash/redelivery loop, so EVERY decode of untrusted edge bytes MUST go through this boundary.

  ## Stage-specific, not module-generic

  The ONLY public entries are a FINITE set of stage decoders -- `decode_client_message/1`,
  `decode_frame/1`, `decode_record/1`, `decode_manifest_page/1`, `decode_assignment_record/1`,
  `decode_plan_header/1`, `decode_plan_page/1`, `decode_compiled_assignment/1`,
  `decode_execution_grant/1`, and `decode_sweep_batch/1` -- each bound to exactly one
  generated edge message module. The recovery, assignment, plan, and sweep-body stages
  EXTEND this set rather than standing up
  separate raw-bytes ingresses, so each gets the same bound-before-decode discipline and the same
  typed outcomes as the transport stages. The plan entries matter especially: protobuf-elixir ERASES
  an unknown GROUP, so plan wire hygiene is only observable on the raw path.
  ONE STAGE IS NOT PHYSICALLY BOUNDED AT 512 KiB: `decode_sweep_batch/1` runs on
  ALREADY-EXTRACTED, uncompressed bytes, where a legitimately decompressed body may exceed
  the record's physical bound. It inherits the 32 MiB extracted-body work ceiling instead.
  See its own doc.
  There is no public "decode any module" entry (that was a bypass: a caller-defined struct decoder
  could return `{:ok, fake_struct}`). A decode result is additionally accepted only when it is
  genuinely a struct of the target module (`is_struct(decoded, mod)`).

  ## Typed outcomes

    * `{:ok, struct}`        -- decoded a real edge protobuf message of the target type.
    * `{:error, :too_large}` -- the RAW bytes exceed the frozen size bound for this stage, checked
                                BEFORE protobuf is invoked. A PERMANENT rejection (an unbounded input
                                is refused, never decoded), distinct from poison.
    * `{:error, :poison}`    -- the BYTES are unrecoverable for this schema (malformed wire). Safe to
                                quarantine. PERMANENT -- only this and `:too_large` resolve a
                                delivery as permanently dead. An unmapped/negative ENUM is NOT
                                poison: it decodes (see below) and is rejected by the SEMANTIC
                                validator as a permanent rejection, matching Go.
    * `{:error, :not_ready}` -- the target decoder module is not loaded (an expected edge schema not
                                yet deployed). Leave the delivery PENDING; a later deploy may decode
                                it. TRANSIENT.
    * `{:error, :systemic}`  -- an UNEXPECTED fault that is NOT a decode-of-bad-bytes: a decoder bug
                                (a raise/throw/exit not attributable to malformed wire or an edge
                                enum), a codegen/metadata defect reported by the structural preflight,
                                or a decode that returned a non-struct. PAUSE; MUST NOT resolve
                                the delivery as poison.

  ## Structural preflight (task 1.5)

  Every stage decode runs `ServiceRadar.Edge.WireValidate` on the raw bytes BEFORE the generated
  decoder. It walks the schema RECURSIVELY -- the inner record and every nested capability, not just
  the frame envelope this module's own scanner covers -- and rejects what Go rejects but
  protobuf-elixir masks or silently discards: groups, out-of-range field numbers, 10-byte
  uint64-overflow varints (including packed elements), mis-sized packed fixed payloads, and
  truncation. Those are `:poison`; a missing/undeployed nested schema is `:not_ready` and a
  codegen/metadata defect is `:systemic`, NEVER poison.

  The preflight is STRUCTURAL ONLY. It makes no value-level judgement, because a raw walker cannot
  reproduce protobuf's EFFECTIVE-value semantics (last-one-wins, oneof resolution, embedded-message
  merging) without reimplementing the decoder -- e.g. `traffic_class = -1` followed by
  `traffic_class = BULK` has the effective value BULK, which Go accepts. Value-level verdicts belong
  to the semantic validator that runs on the DECODED struct.

  ## Classification is STACK-INDEPENDENT (by exception value, never the stacktrace)

  A permanent data-loss (poison) decision must not depend on VM state such as
  `:erlang.system_flag(:backtrace_depth, N)` or stacktrace layout, NOR on an exception shape that has
  a NON-data origin. `protobuf-elixir` (0.16, one generic `Protobuf.Decoder`) surfaces failures as
  three exception SHAPES, discriminated by the exception's OWN fields:

    * `%Protobuf.DecodeError{}` -> the decoder's DELIBERATE, typed malformed-wire error -> `:poison`.
      This is the only unambiguous "these bytes are unrecoverable" signal.
    * `%FunctionClauseError{}` -> `:systemic`, ALWAYS. The generated edge enums carry injected
      negative identity clauses (`scripts/patch_edge_enum_negatives.exs`) and the DSL's own catchall
      covers every non-negative integer, so `key/1`/`value/1` are TOTAL over integers and no wire
      bytes can legitimately raise this. If it is raised the transform is missing/corrupt or codegen
      drifted -- a deployment defect, which must PAUSE, never permanently resolve a delivery.
    * `%MatchError{}` -> AMBIGUOUS -> `:systemic` (NOT poison). A `MatchError` is raised both by
      malformed wire AND by non-data protobuf runtime sites (bad generated message/oneof metadata), so
      permanently poisoning it would let a deployment/codegen defect destroy valid customer data. Until
      a project-owned typed malformed-wire result exists (task 1.5), an ambiguous `MatchError` PAUSES
      (systemic), never permanently resolves.
    * anything else -- any other exception/throw/exit -> a genuine decoder bug -> `:systemic` (the
      default), never silent poison.

  Empirically (~13k fuzz inputs), decoding edge messages yields only those exception shapes, and
  malformed wire never produced a `FunctionClauseError`.

  ## Enum parity (task 1.5)

  An unmapped NEGATIVE enum is protobuf-valid data Go RETAINS as its integer and then rejects in the
  explicit semantic validator. protobuf-elixir's generated `key/1` was guarded `tag >= 0` and RAISED
  -- and because the decoder walks fields IN ORDER while protobuf resolves a repeated singular field
  LAST-ONE-WINS, `traffic_class = -1` followed by `traffic_class = BULK` (effective value BULK,
  which Go ACCEPTS) blew up on the FIRST occurrence, so Elixir REJECTED a message Go ACCEPTS.
  `scripts/patch_edge_enum_negatives.exs` injects negative identity clauses into the generated edge
  enums so the integer is RETAINED exactly as Go retains it, and
  `ServiceRadar.Edge.SemanticValidate` then rejects any retained non-member on the DECODED struct --
  where the effective value is already resolved -- with the stage-correct disposition.
  """

  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireValidate

  @typedoc """
  Every reason a decode can fail with. EXPORTED so a caller composing its own reason union
  references this instead of copying the atoms -- a copy drifts the moment a reason is added.
  """
  @type reason :: :too_large | :poison | :not_ready | :systemic

  @typedoc "Typed decode outcome; only `:poison`/`:too_large` authorize permanent resolution."
  @type outcome :: {:ok, struct()} | {:error, reason()}

  # Frozen RAW wire size bounds, MUST match the Go constants in go/pkg/edge/edgerecord (MaxRecordBytes
  # / MaxFrameBytes / MaxClientMessageBytes). Checked BEFORE protobuf decode so an oversize input is a
  # permanent rejection rather than an unbounded decode.
  @max_record_bytes 512 * 1024
  # The carrier's PHYSICAL ceiling, frozen in the ABI bounds table. It travels standalone,
  # so it does not inherit a containing message's bound.
  @max_compiled_assignment_bytes 64 * 1024
  # The standalone execution grant's ceiling, frozen in the ABI bounds table.
  @max_execution_grant_bytes 16 * 1024
  @max_plan_page_bytes 128 * 1024
  # The PLAN HEADER's own physical ceiling, mirroring Go's `edgerecord.MaxPlanHeaderBytes`.
  # DELIBERATELY INDEPENDENT of `@max_record_bytes` even though both are 512 KiB today: the
  # header is not a record and does not inherit a record's budget, so aliasing them would make
  # the two runtimes agree by coincidence of VALUE rather than by construction. The shared
  # scalar corpus freezes the value and both runtimes check their own constant against it, so
  # a move on either side is caught -- this constant is what gives this runtime something to
  # move.
  @max_plan_header_bytes 512 * 1024
  @max_delivery_envelope_bytes 16 * 1024
  @max_frame_bytes @max_record_bytes + @max_delivery_envelope_bytes
  @max_client_message_bytes @max_frame_bytes + 8
  # Whole-manifest budget, mirroring Go's edgerecord.MaxManifestBytes. Used as the
  # per-page ceiling too: one page can never be larger than the entire manifest.
  # The EXTRACTED-BODY work ceiling, mirroring Go's MaxUncompressedBytes. It bounds a body
  # AFTER decompression, where the 512 KiB physical record bound no longer applies.
  @max_extracted_body_bytes 32 * 1024 * 1024
  @max_manifest_bytes 256 * 1024

  # Protobuf field numbers for the RAW outer-wire peel (P1-2). EdgeRecordClientMessage is a oneof of
  # lane_open (field 1) / delivery_frame (field 2); EdgeDeliveryFrameV1.record_bytes is field 5.
  @client_message_lane_open_field 1
  @client_message_frame_field 2
  @frame_record_bytes_field 5
  # Max protobuf field number (2^29 - 1). A tag whose field number exceeds this (an overflow/masking
  # varint the generated decoder might reinterpret) is rejected rather than trusted.
  @max_field_number WireValidate.max_field_number()

  # protobuf-elixir counts EMBEDDED levels (the root is depth 0) while `WireValidate` counts
  # messages INCLUDING the root, so 10,000 messages == 9,999 embedded levels. Deriving this from
  # WireValidate keeps the decoder and the preflight from drifting apart.
  @max_nesting_depth WireValidate.max_message_depth() - 1

  @doc """
  Decodes the raw bytes of an `EdgeRecordClientMessage` -- the gRPC ingress request type on
  `EdgeRecordIngestService.Stream` (a `lane_open` / `delivery_frame` oneof). This MUST be the FIRST
  decode of the untrusted transport bytes (behind a pre-handler raw codec); the generated gRPC codec
  would otherwise decode the whole message -- including `lane_open.traffic_class` -- and crash before
  a handler could quarantine it. See `t:outcome/0`.
  """
  @spec decode_client_message(binary()) :: outcome()
  def decode_client_message(bytes) when is_binary(bytes) do
    # RAW OUTER-wire scan: the generated decode of an EdgeRecordClientMessage would collapse duplicate/
    # nested fields of the inner delivery_frame WITHOUT relational-envelope accounting, so a bloated frame
    # wrapped in field 2 (or hidden behind a duplicate frame, a group, or an overflow tag) would slip
    # through. `scan_client_message/1` enforces the outer ONEOF (exactly one payload) and extracts the
    # exact nested frame; it FAILS CLOSED (`:reject` -> `:poison`) on a duplicate payload, a group, an
    # overflow/out-of-range tag, or truncation -- it NEVER falls through to the generated decode on a
    # scan failure. Only a single, cleanly-scanned frame's envelope is then checked before decode.
    # Oversize raw bytes are a PERMANENT rejection (:too_large), checked before the scan so an
    # over-bound input is not reclassified as :poison.
    if byte_size(bytes) > @max_client_message_bytes do
      {:error, :too_large}
    else
      case scan_client_message(bytes) do
        {:frame, frame_raw} ->
          case raw_frame_envelope_check(frame_raw) do
            :ok -> run(EdgeRecordClientMessage, @max_client_message_bytes, bytes)
            {:error, _} = err -> err
          end

        :no_frame ->
          run(EdgeRecordClientMessage, @max_client_message_bytes, bytes)

        :reject ->
          {:error, :poison}
      end
    end
  end

  def decode_client_message(_bytes), do: {:error, :systemic}

  @doc """
  Decodes the raw bytes of an `EdgeDeliveryFrameV1` (e.g. a frame re-read from durable storage on the
  JetStream path). Its inner `record_bytes` is opaque here and MUST be decoded separately with
  `decode_record/1`. Also enforces the RELATIONAL envelope budget on the EXACT raw wire bytes via a raw
  peel of `record_bytes` (field 5): the non-record overhead MUST fit the 16 KiB budget. Using the RAW
  wire (not the canonical size) catches duplicate/non-minimal fields -- e.g. a 1-byte record with 20 KiB
  of duplicate `sequence` fields -> `:too_large`. See `t:outcome/0`.
  """
  @spec decode_frame(binary()) :: outcome()
  def decode_frame(bytes) when is_binary(bytes) do
    case raw_frame_envelope_check(bytes) do
      :ok -> run(EdgeDeliveryFrameV1, @max_frame_bytes, bytes)
      {:error, _} = err -> err
    end
  end

  def decode_frame(_bytes), do: {:error, :systemic}

  @doc """
  Decodes the raw `frame.record_bytes` of a delivery frame as an `EdgeRecordV1` -- the second ingress
  stage, distinct from the outer client-message/frame decode. See `t:outcome/0`.
  """
  @spec decode_record(binary()) :: outcome()
  def decode_record(bytes), do: run(EdgeRecordV1, @max_record_bytes, bytes)

  @doc """
  Decode a scheduler-authored `SweepAssignmentRecordV1`.

  It goes through the SAME classifier as every other edge decode rather than a local
  `rescue`: the deliberate `:not_ready` / `:systemic` / `:poison` distinction, the
  throw/exit handling, and the nesting bound all live here. A caller that decodes
  directly and maps every exception to `:poison` turns a codegen or
  not-yet-deployed-module fault into permanent quarantine.
  """
  @spec decode_assignment_record(binary()) :: outcome()
  def decode_assignment_record(bytes),
    do: run(Serviceradar.Edge.V1.SweepAssignmentRecordV1, @max_record_bytes, bytes)

  @doc """
  Decode an immutable scheduler plan HEADER from raw bytes.

  Curated because the plan is CONTENT-ADDRESSED: protobuf-elixir ERASES an unknown
  GROUP (wire types 3/4) rather than retaining it, so a decoded header cannot be asked
  whether it carried one. Go retains and rejects it. Only the raw structural walk sees
  those bytes, which is why plan validation from a decoded struct alone cannot claim
  wire-hygiene parity.
  """
  @spec decode_plan_header(binary()) :: outcome()
  def decode_plan_header(bytes),
    do: run(Serviceradar.Edge.V1.ScheduledPlanHeaderV1, @max_plan_header_bytes, bytes)

  @doc "Decode one immutable scheduler plan PAGE from raw bytes. See decode_plan_header/1."
  @spec decode_plan_page(binary()) :: outcome()
  def decode_plan_page(bytes),
    do: run(Serviceradar.Edge.V1.ScheduledPlanPageV1, @max_plan_page_bytes, bytes)

  @doc """
  Decode an immutable `CompiledSweepAssignmentV1` from raw bytes.

  Curated for two reasons a local `rescue` cannot supply. First, the 64 KiB ceiling is
  PHYSICAL: the carrier is fetched standalone by digest, and a duplicate-known-field
  encoding collapses on decode, so only a bound taken BEFORE decoding sees the received
  size. Second, the recursive `WireValidate` gate rejects the inputs protobuf-elixir
  masks but Go rejects -- groups, out-of-range field numbers, overflow varints,
  truncation -- at every depth, including the nested capability and its claim. A caller
  decoding directly would silently accept those AND collapse a codegen or
  not-yet-deployed fault into permanent poison.
  """
  @spec decode_compiled_assignment(binary()) :: outcome()
  def decode_compiled_assignment(bytes),
    do: run(Serviceradar.Edge.V1.CompiledSweepAssignmentV1, @max_compiled_assignment_bytes, bytes)

  @doc """
  Decode a standalone ASSIGNMENT_EXECUTION grant -- an `EdgeSignedCapabilityV1` that travels on
  its own rather than nested inside a record.

  Its 16 KiB ceiling is SMALLER than any message that embeds a capability, and that is the
  point: a capability read out of a containing message inherits that message's bound, but this
  one arrives alone and would otherwise be unbounded. Same module as other capabilities, a
  different ceiling because of how it travels.
  """
  @spec decode_execution_grant(binary()) :: outcome()
  def decode_execution_grant(bytes),
    do: run(Serviceradar.Edge.V1.EdgeSignedCapabilityV1, @max_execution_grant_bytes, bytes)

  @doc """
  Decode ONE `SweepObservationBatchV1` from ALREADY-EXTRACTED, UNCOMPRESSED protobuf bytes
  (task 1.2-c).

  ## The ceiling here is the EXTRACTED-BODY WORK ceiling, not the record's 512 KiB

  512 KiB is the PHYSICAL bound on the outer record and its encoded/compressed payload. A
  compressed payload under that bound may legitimately EXPAND past it: Go decompresses up to
  `MaxUncompressedBytes` (32 MiB, ratio <= 100) and then decodes the result with NO second
  512 KiB cap. Applying the physical bound here would permanently reject a valid record whose
  ZSTD body expands beyond it.

  So this stage inherits the 32 MiB extracted-body work ceiling. It is deliberately NOT a
  sweep-specific limit -- a separate one would be a second, divergent bound on the same
  bytes.

  ## What this function does NOT do

  It does not decompress, does not check the compression ratio, and does not reject trailing
  frames. ZSTD extraction and the normative 32 MiB freeze belong to task 1.5-f; this stage
  runs on its output. Passing still-compressed bytes here is a caller error, not something
  this function detects.

  Bound-before-decode and the recursive wire-hygiene gate come from `run/3`, the same path
  every other curated decoder uses, so unknown-field rejection and the
  `:poison` / `:not_ready` / `:systemic` classification are the ones already frozen.
  """
  @spec decode_sweep_batch(term()) :: outcome()
  def decode_sweep_batch(bytes),
    do: run(Serviceradar.Edge.V1.SweepObservationBatchV1, @max_extracted_body_bytes, bytes)

  @doc """
  Decodes ONE raw `EdgeLossManifestPageV1` -- the recovery-page ingress stage.

  This EXTENDS the finite stage API rather than superseding it, and deliberately so:
  a recovery page arrives as raw bytes and needs the same bound-BEFORE-decode
  discipline, the same recursive `WireValidate` gate, and the same typed outcomes as
  the transport stages. Standing up a separate raw-bytes ingress for it would leave
  two boundaries claiming the same guarantee, with only one of them maintained.

  The page ceiling is `@max_manifest_bytes`, the whole-manifest budget: no single
  page may exceed what the entire manifest is allowed. The AGGREGATE budget across a
  chain is enforced by `ServiceRadar.Edge.RecoveryValidate.manifest_chain_from_raw/2`,
  which sums exact received lengths -- a per-page check alone cannot see it. See
  `t:outcome/0`.
  """
  @spec decode_manifest_page(binary()) :: outcome()
  def decode_manifest_page(bytes), do: run(EdgeLossManifestPageV1, @max_manifest_bytes, bytes)

  # Internal decode engine shared by the stage decoders. PRIVATE so there is no generic decode-any-
  # module bypass: only the CURATED message modules can be decoded, and only their own struct is
  # accepted (is_struct/2). The moduledoc holds the ONE canonical list of those stages; this
  # comment deliberately does not restate it, because a second enumeration -- this one was by
  # CATEGORY rather than by function name -- goes stale invisibly.
  defp run(mod, max_bytes, bytes) when is_binary(bytes) do
    cond do
      # Oversize is refused BEFORE protobuf is invoked -> permanent rejection, not an unbounded decode.
      byte_size(bytes) > max_bytes -> {:error, :too_large}
      # An expected edge decoder that is not deployed yet -> pause, do not quarantine.
      not Code.ensure_loaded?(mod) -> {:error, :not_ready}
      true -> validated_attempt(mod, bytes)
    end
  end

  # A non-binary argument is a caller/programming fault, never permanent poison.
  defp run(_mod, _max_bytes, _bytes), do: {:error, :systemic}

  # RECURSIVE STRUCTURAL wire-hygiene gate (task 1.5) BEFORE the generated decode. The top-level
  # scanner above only covers the frame envelope; `WireValidate` walks the schema at EVERY message
  # depth -- the inner record and every nested capability -- rejecting the inputs protobuf-elixir
  # masks or silently discards but Go rejects (groups, out-of-range field numbers, 10-byte
  # uint64-overflow varints incl. packed elements, truncation) as `:poison`. It reports a
  # codegen/metadata defect as `:systemic`/`:not_ready`, NEVER poison. It makes NO value-level
  # judgement -- see its moduledoc for why effective-value semantics belong to the semantic layer.
  defp validated_attempt(mod, bytes) do
    case WireValidate.validate(bytes, mod) do
      :ok -> attempt(mod, bytes)
      {:error, _} = err -> err
    end
  end

  defp attempt(mod, bytes) do
    # `mod.decode/1` uses protobuf-elixir's DEFAULT `:max_nesting_depth` of 100 embedded levels,
    # which would reject nesting the preflight (and Go) accept -- making the end-to-end parity claim
    # false. `Protobuf.decode/3` takes the option, so the decoder is aligned with the SAME bound
    # WireValidate enforces: 10,000 messages counting the root == 9,999 embedded levels.
    decoded = Protobuf.decode(bytes, mod, max_nesting_depth: @max_nesting_depth)

    # Reject an enum module / fake / wrong-type result that decoded WITHOUT raising: only a genuine
    # struct of the TARGET module is an accepted message.
    if is_struct(decoded, mod), do: {:ok, decoded}, else: {:error, :systemic}
  rescue
    error -> {:error, classify(error)}
  catch
    # A throw/exit is never a "bad bytes" decode result; leave the delivery unresolved.
    _kind, _reason -> {:error, :systemic}
  end

  @doc false
  # PURE, stack-independent classifier: maps a rescued decode exception to :poison (bad bytes) or
  # :systemic (decoder bug). Public only so classification can be unit-tested directly; it decodes
  # nothing and cannot leak `{:ok, _}`, so it is not a decode bypass. Keys ONLY on the exception's own
  # value (type + `FunctionClauseError.module`), never the stacktrace.
  @spec classify(Exception.t()) :: :poison | :systemic
  def classify(%Protobuf.DecodeError{}), do: :poison

  # An edge-enum FunctionClauseError is NO LONGER wire poison. The generated edge enums are patched
  # (scripts/patch_edge_enum_negatives.exs) with negative identity clauses, and the DSL's own
  # catchall covers every non-negative integer, so `key/1`/`value/1` are TOTAL over integers: no
  # sequence of wire bytes can legitimately raise it any more. If it is raised, the transform is
  # missing or corrupt (or codegen drifted) -- a deployment defect, which must PAUSE (`:systemic`),
  # never permanently resolve a delivery as quarantined/dead.
  def classify(%FunctionClauseError{}), do: :systemic

  # A MatchError is ambiguous (malformed wire OR a codegen/metadata bug), so it is systemic, never a
  # permanent poison -- a deployment defect must not destroy valid data.
  def classify(%MatchError{}), do: :systemic

  def classify(_other), do: :systemic

  # raw_frame_envelope_check/1: enforce, STRICTLY IN ORDER, (1) the frame's HARD total-size bound, (2) a
  # MALFORMED envelope, then (3) the relational non-record envelope budget, on the EXACT raw wire bytes of
  # an EdgeDeliveryFrameV1. Peels the LAST record_bytes (field 5) value -- exactly what proto decode keeps
  # (last-wins) -- so for a well-formed peel `raw_total - record_len` is the exact non-record overhead,
  # counting duplicate/non-minimal fields the canonical size would collapse. Returns :ok |
  # {:error, :too_large} | {:error, :poison}.
  #
  # ORDER MATTERS. A :malformed peel (an unknown GROUP -- wire type 3/4 -- truncation, or an overflow tag)
  # yields NO known record_len, so the relational check (which subtracts record_len) CANNOT run over it:
  # with record_len forced to 0 it would count a large but LEGITIMATE record as pure overhead and
  # misclassify a group-bearing 20 KiB-record frame as `:too_large` (REJECTED_PERMANENT) when the frozen
  # path for wire poison is `:poison` (ACCEPTED_QUARANTINE). So a malformed peel resolves to :poison BEFORE
  # the relational budget. protobuf-elixir SILENTLY DROPS such a group (`decode_frame(<<0x33, 0x34, 0x2A,
  # 0x01, 0x00>>)` returns {:ok, ...} with the group gone) whereas Go retains + REJECTS it, so poisoning
  # here restores parity. The HARD total-frame bound still fires FIRST: an oversize frame is permanent
  # regardless of structure. An :absent peel (a clean scan with genuinely no field 5) keeps record_len 0,
  # which is CORRECT -- every byte then IS overhead -- so the relational budget legitimately applies to it.
  # NOTE: groups NESTED inside the record bytes or inside capabilities are opaque to this top-level peel;
  # rejecting those recursively at every message depth is task 1.5's protobuf-elixir patch.
  defp raw_frame_envelope_check(frame_raw) when is_binary(frame_raw) do
    peeled = peel_last_field(frame_raw, @frame_record_bytes_field)

    record_len =
      case peeled do
        {:ok, value} -> byte_size(value)
        _ -> 0
      end

    cond do
      byte_size(frame_raw) > @max_frame_bytes -> {:error, :too_large}
      peeled == :malformed -> {:error, :poison}
      byte_size(frame_raw) - record_len > @max_delivery_envelope_bytes -> {:error, :too_large}
      true -> :ok
    end
  end

  # scan_client_message/1: enforce the outer ONEOF and extract the single delivery_frame. Returns
  # {:frame, value} (exactly one delivery_frame payload) | :no_frame (one lane_open, or an empty message)
  # | :reject. It FAILS CLOSED to :reject on: MORE THAN ONE payload occurrence (a duplicate outer oneof,
  # incl. a bloated frame + a decoy tiny frame); a delivery_frame with the wrong wire type; a GROUP
  # (wire type 3/4); an out-of-range/OVERFLOW field number a generated decoder might reinterpret; or
  # truncation. It NEVER falls through to the generated decode on a scan failure.
  defp scan_client_message(bin), do: scan_client_message(bin, 0, nil)

  defp scan_client_message(<<>>, payloads, frame) do
    cond do
      payloads > 1 -> :reject
      frame != nil -> {:frame, frame}
      true -> :no_frame
    end
  end

  defp scan_client_message(bin, payloads, frame) do
    case take_varint(bin) do
      {tag, rest} ->
        wire_type = Bitwise.band(tag, 0x07)
        field = Bitwise.bsr(tag, 3)

        if field < 1 or field > @max_field_number do
          :reject
        else
          scan_client_field(field, wire_type, rest, payloads, frame)
        end

      :error ->
        :reject
    end
  end

  defp scan_client_field(field, wire_type, rest, payloads, frame) do
    case take_field(wire_type, rest) do
      {value, rest2} ->
        cond do
          field == @client_message_frame_field and wire_type == 2 ->
            scan_client_message(rest2, payloads + 1, value)

          field == @client_message_frame_field ->
            :reject

          field == @client_message_lane_open_field ->
            scan_client_message(rest2, payloads + 1, frame)

          true ->
            scan_client_message(rest2, payloads, frame)
        end

      :error ->
        :reject
    end
  end

  # peel_last_field/2: the LAST length-delimited (wire type 2) value for `field_num` in a raw protobuf
  # message. {:ok, value_binary} | :absent | :malformed. A minimal top-level scanner over varint tags and
  # wire types 0/1/2/5; groups (3/4), truncation, and an out-of-range/OVERFLOW field number (< 1 or
  # > @max_field_number) are :malformed. The field-number bound MATTERS for parity: protobuf-elixir MASKS a
  # 10-byte overflow tag to 64 bits and can decode `(1 <<< 64) ||| 0x2A` as a real field-5 record, whereas
  # an UNBOUNDED peel would read a ~2^61 field, treat it as "not the record", and return :absent -> a silent
  # {:ok}; Go rejects an out-of-range field number. Bounding here (like scan_client_message) fails such a
  # frame closed. Used for the frame's record_bytes peel: :absent (a clean scan with no field 5) makes the
  # overhead conservative (record_len 0), while :malformed is failed closed to :poison by the caller so a
  # silently-dropped group or a masked overflow tag cannot be admitted.
  defp peel_last_field(bin, field_num), do: peel_last_field(bin, field_num, :absent)

  defp peel_last_field(<<>>, _field_num, acc), do: acc

  defp peel_last_field(bin, field_num, acc) do
    with {tag, rest} <- take_varint(bin),
         wire_type = Bitwise.band(tag, 0x07),
         field = Bitwise.bsr(tag, 3),
         true <- field >= 1 and field <= @max_field_number,
         {value, rest2} <- take_field(wire_type, rest) do
      acc = if field == field_num and wire_type == 2, do: {:ok, value}, else: acc
      peel_last_field(rest2, field_num, acc)
    else
      _ -> :malformed
    end
  end

  # take_varint/1 and take_field/2 are DELEGATED to `WireValidate`, which owns the single
  # implementation of the wire primitives. This scanner (frame TOP level) and the recursive
  # validator (every message depth) MUST agree byte-for-byte on varint/field framing -- notably the
  # 10th-byte uint64-overflow rule that matches `protowire.ConsumeVarint` -- so a second copy here
  # could drift out of Go parity silently. See `ServiceRadar.Edge.WireValidate`.
  defp take_varint(bin), do: WireValidate.take_varint(bin)

  defp take_field(wire_type, bin), do: WireValidate.take_field(wire_type, bin)
end
