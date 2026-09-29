defmodule ServiceRadar.Edge.WireValidate do
  @moduledoc """
  Project-owned RECURSIVE protobuf STRUCTURAL wire-hygiene validator for edge messages (task 1.5).

  `protobuf-elixir`'s generated decoders are LENIENT in ways the Go side is not: they silently
  DISCARD unknown groups, leniently accept out-of-range field numbers, and MASK 10-byte varints to
  their low 64 bits. The Go side rejects all three, though at DIFFERENT layers, which matters for
  describing this module honestly:

    * out-of-range field numbers and 10-byte uint64-overflow varints are rejected by Go's WIRE
      PARSER (`protowire`: `MaxValidNumber`, and `ConsumeVarint`'s `if y < 2` overflow guard);
    * a well-formed unknown GROUP is PARSED and RETAINED by Go as an unknown field -- it is
      ServiceRadar's own unknown-field validation that then rejects the message.

  Either way the Go side ends up REJECTING and protobuf-elixir would ADMIT, because it drops the
  group entirely so no unknown-field check can ever see it. Left unclosed, a frame whose record or
  nested capability carries any of them decodes `{:ok, ...}` in Elixir while the Go side rejects it
  -- an admit-vs-reject divergence on a durable-record boundary.

  `ServiceRadar.Edge.WireDecode`'s scanner closes these at the FRAME TOP level only. This module
  closes them at EVERY message depth by walking the raw bytes against the generated schema
  (`__message_props__/0`), recursing ONLY into fields the schema marks as embedded messages (so a
  `bytes`/`string` field whose content happens to look like protobuf is never misparsed).

  ## Scope: STRUCTURAL hygiene ONLY -- deliberately NOT semantic

  This walker answers one question: "would the GO SIDE reject these bytes?" -- which is Go's wire
  parser PLUS ServiceRadar's own frozen-ABI policy, since some of what we reject is retained rather
  than rejected by protowire itself (a well-formed unknown group or an ordinary in-range unknown
  field is PARSED and RETAINED by Go, then rejected by the recursive unknown-field validators).
  It NEVER interprets field VALUES, because a raw walker cannot reproduce protobuf's EFFECTIVE-value
  semantics without reimplementing the decoder:

    * LAST-ONE-WINS -- a repeated occurrence of a singular field overrides earlier ones, so a
      first-occurrence verdict is simply wrong (`traffic_class = -1` followed by
      `traffic_class = BULK` has the effective value BULK, which Go accepts).
    * ONEOF resolution and EMBEDDED-MESSAGE MERGING compound this at every depth.

  Value-level verdicts (unknown/negative enums, version/unit/range/bound checks) therefore belong to
  the SEMANTIC validator that runs on the DECODED struct, where the effective value is already
  resolved by the real decoder. See `ServiceRadar.Edge.WireDecode` for the decode-stage contract.

  ## Outcomes

    * `:ok`                   -- the bytes are structurally wire-clean at every depth for this schema.
    * `{:error, :poison}`     -- a wire-hygiene violation the Go side rejects: a GROUP (wire type 3/4) or
                                 reserved wire type (6/7), a field number outside `1..2^29-1` (Go's
                                 `MaxValidNumber`), a 10-byte uint64-overflow varint (terminal chunk
                                 > 1) in ANY varint position (tag, wire-0 scalar, packed element, or
                                 length prefix), a mis-sized packed fixed-width payload, an ORDINARY
                                 RETAINED UNKNOWN FIELD (a field number not in the schema -- the
                                 frozen ABI rejects these recursively), truncation, or nesting
                                 deeper than the Go parser's limit.
    * `{:error, :not_ready}`  -- a nested edge schema module is not loaded (an expected message type
                                 not yet deployed). TRANSIENT: leave the delivery unresolved.
    * `{:error, :systemic}`   -- a codegen/metadata defect (a schema module that is loaded but is not
                                 a walkable message, or whose metadata raises). PAUSE.

  A metadata failure is NEVER reported as `:poison`: poison permanently resolves a delivery as dead,
  and a deployment/codegen defect must not destroy valid customer data.
  """

  import Bitwise

  # Go's protowire MaxValidNumber (2^29 - 1), inclusive. A tag whose field number exceeds it is
  # rejected by Go and must be rejected here.
  @max_field_number 0x1FFFFFFF

  # Nesting bound, aligned EXACTLY with the pinned Go runtime (google.golang.org/protobuf v1.36.11,
  # `protowire.DefaultRecursionLimit`). Go counts the ROOT: `unmarshalMessage` runs
  # `if o.RecursionLimit--; o.RecursionLimit < 0 { errRecursionDepth }` for the root message too, so
  # a chain of 10,000 messages (root + 9,999 nested) is ACCEPTED and the 10,001st is rejected. Here
  # the root walks at depth 0, so message N is at depth N-1 and the guard is `depth >= @max_depth`.
  # The edge roots are acyclic today, so this is a stack-safety backstop, not a live gate -- but it
  # must match Go for the parity claim to hold generically.
  @max_depth 10_000

  # Wire-encoding families, used to validate PACKED repeated payloads (a length-delimited run of
  # elements). Without this a packed int32 carrying a 2^64+N element would mask in Elixir while Go
  # rejects it -- the same divergence class this module exists to close.
  @varint_types [:int32, :int64, :uint32, :uint64, :sint32, :sint64, :bool]
  @fixed32_types [:fixed32, :sfixed32, :float]
  @fixed64_types [:fixed64, :sfixed64, :double]

  @type outcome :: :ok | {:error, :poison} | {:error, :not_ready} | {:error, :systemic}

  @doc """
  Validates raw protobuf `bytes` against the generated message module `mod`, recursively.

  Total: never raises. A module that is not loaded yields `{:error, :not_ready}`; one that is loaded
  but carries no walkable message metadata yields `{:error, :systemic}`.
  """
  @spec validate(binary(), module()) :: outcome()
  def validate(bytes, mod) when is_binary(bytes) and is_atom(mod) do
    case message_props(mod) do
      {:ok, props} -> walk(bytes, props, 0)
      {:error, _} = err -> err
    end
  end

  # A non-binary/non-module argument is a caller fault, not bad bytes.
  def validate(_bytes, _mod), do: {:error, :systemic}

  @doc """
  Consumes one base-128 varint: `{value, rest}` | `:error`.

  A VALID uint64 varint (<= 10 bytes) -- NOT a canonical/minimal one: Go-compatible NON-MINIMAL
  encodings (e.g. `1` written in 10 bytes) are ACCEPTED, exactly as Go/protowire accepts them.
  Bytes 1-9 (shift 0..56) carry 7 bits each. The 10th byte (shift 63) holds ONLY bit 63, so it MUST
  be TERMINAL with chunk 0 or 1: a continuation bit at byte 10, or a terminal chunk >= 2, sets bits
  >= 64 (uint64 OVERFLOW) and is `:error`, matching `protowire.ConsumeVarint`'s `if y < 2` guard.
  Without this a `2^64 + N` varint is accepted here as an Elixir bignum while the generated decoder
  MASKS it to `N` -- an admit-vs-reject divergence.
  """
  @spec take_varint(binary()) :: {non_neg_integer(), binary()} | :error
  def take_varint(bin), do: take_varint(bin, 0, 0)

  defp take_varint(<<1::1, chunk::7, rest::binary>>, shift, acc) when shift < 63,
    do: take_varint(rest, shift + 7, bor(acc, bsl(chunk, shift)))

  defp take_varint(<<0::1, chunk::7, rest::binary>>, shift, acc) when shift < 63,
    do: {bor(acc, bsl(chunk, shift)), rest}

  defp take_varint(<<0::1, chunk::7, rest::binary>>, 63, acc) when chunk <= 1,
    do: {bor(acc, bsl(chunk, 63)), rest}

  defp take_varint(_, _, _), do: :error

  @doc """
  Consumes one field's payload by wire type: `{value_or_nil, rest}` | `:error`.

  Only wire type 2 yields a value binary (the length-delimited payload); 0/1/5 are skipped (`nil`).
  Groups (3/4) and the reserved wire types (6/7) are `:error`. Go's parser RETAINS a well-formed
  unknown group as an unknown field (ServiceRadar's unknown-field validation then rejects the
  message), whereas protobuf-elixir silently DROPS it so no such check can ever see it -- rejecting
  here is what keeps the two sides' accept/reject verdicts aligned.
  """
  @spec take_field(non_neg_integer(), binary()) :: {binary() | nil, binary()} | :error
  def take_field(0, bin) do
    case take_varint(bin) do
      {_v, rest} -> {nil, rest}
      :error -> :error
    end
  end

  def take_field(1, <<_::binary-size(8), rest::binary>>), do: {nil, rest}

  def take_field(2, bin) do
    case take_varint(bin) do
      {len, rest} when byte_size(rest) >= len ->
        <<value::binary-size(len), rest2::binary>> = rest
        {value, rest2}

      _ ->
        :error
    end
  end

  def take_field(5, <<_::binary-size(4), rest::binary>>), do: {nil, rest}
  def take_field(_wire_type, _bin), do: :error

  @doc "Go's `MaxValidNumber` (2^29 - 1): the inclusive upper bound on a protobuf field number."
  @spec max_field_number() :: pos_integer()
  def max_field_number, do: @max_field_number

  @doc """
  The maximum number of messages in one nesting chain, COUNTING THE ROOT, matching the pinned Go
  runtime's `protowire.DefaultRecursionLimit`. Callers that count EMBEDDED levels instead (as
  protobuf-elixir's `:max_nesting_depth` does) must subtract one.
  """
  @spec max_message_depth() :: pos_integer()
  def max_message_depth, do: @max_depth

  # ---- recursive walk -------------------------------------------------------------------------

  defp walk(_bin, _props, depth) when depth >= @max_depth, do: {:error, :poison}
  defp walk(<<>>, _props, _depth), do: :ok

  defp walk(bin, props, depth) do
    case take_varint(bin) do
      {tag, rest} ->
        field = bsr(tag, 3)
        wire_type = band(tag, 0x07)

        cond do
          field < 1 or field > @max_field_number ->
            {:error, :poison}

          # UNKNOWN FIELD. The edge ABI is frozen and REJECTS retained unknown fields recursively
          # (Go does this in `DecodeRecord`/`ValidateDeliveryFrame`/`ValidateCapability`, and the
          # frozen task-1.16 table classifies an inner-record unknown field as WIRE POISON at a
          # trustworthy slot). protobuf-elixir instead RETAINS it in `__unknown_fields__` and the
          # struct decodes cleanly, so without this an ordinary unknown field would sail through the
          # decode boundary and reach semantic admission. Rejecting on the raw walk catches it at
          # EVERY depth -- inside oneof members, repeated messages and message-valued maps alike --
          # because those are all just nested messages to this walker.
          field_props(props, field) == nil ->
            {:error, :poison}

          true ->
            consume(wire_type, rest, field_props(props, field), props, depth)
        end

      :error ->
        {:error, :poison}
    end
  end

  # wire 2: length-delimited. Recurse ONLY into schema-declared embedded messages; validate the
  # elements of a packed repeated scalar; treat anything else (bytes/string/unknown) as opaque.
  defp consume(2, bin, fprops, props, depth) do
    case take_field(2, bin) do
      {payload, rest} ->
        case descend(fprops, payload, depth) do
          :ok -> walk(rest, props, depth)
          {:error, _} = err -> err
        end

      :error ->
        {:error, :poison}
    end
  end

  # wire 0/1/5 carry no nested structure; 3/4 (groups) and 6/7 are :error. take_field/2 applies the
  # varint overflow rule to the wire-0 value and the truncation rule to the fixed widths.
  defp consume(wire_type, bin, _fprops, props, depth) do
    case take_field(wire_type, bin) do
      {_value, rest} -> walk(rest, props, depth)
      :error -> {:error, :poison}
    end
  end

  # NOTE the metadata shapes differ: an EMBEDDED message field's `type` is the BARE module atom
  # (`Serviceradar.Edge.V1.EdgeRecordLaneOpen`), whereas an ENUM field's is the tagged
  # `{:enum, Mod}`. Matching `{:message, Mod}` here silently never fires and disables all recursion.
  defp descend(%{embedded?: true, type: mod}, payload, depth) when is_atom(mod) do
    case message_props(mod) do
      {:ok, nested} -> walk(payload, nested, depth + 1)
      # A nested schema that is missing/undeployed is a METADATA failure, never poison: permanently
      # resolving a delivery because of a deployment defect would destroy valid data.
      {:error, _} = err -> err
    end
  end

  # ONLY a REPEATED scalar field can carry a packed payload. A SINGULAR scalar that arrives
  # length-delimited is a wire-type MISMATCH, which Go's PARSER does not reject: it preserves the
  # bytes as an unknown field. Composed Go admission then DOES reject the message -- `DecodeRecord`
  # returns `ErrUnknownFields` for exactly that shape -- so the gate is not about matching an
  # accept. It is about WHERE the refusal comes from: applying the packed rules here would refuse
  # it as a malformed PACKED PAYLOAD, a claim about bytes Go's parser reads happily, and would do
  # so on any singular field a future schema adds. The refusal is left to the decoder, which raises
  # `Protobuf.DecodeError` -> `:poison`, matching Go's verdict. Shared vector:
  # `wire_compat_wire_type_mismatch.bin`.
  defp descend(%{repeated?: true, type: type}, payload, _depth), do: packed_payload(type, payload)
  defp descend(_fprops, _payload, _depth), do: :ok

  # A length-delimited payload on a REPEATED scalar field is a packed encoding: varint-typed
  # elements get the same overflow rule as a wire-0 scalar, and fixed-width elements must exactly
  # fill the payload (Go rejects a partial trailing element).
  defp packed_payload({:enum, _mod}, payload), do: walk_packed_varints(payload)
  defp packed_payload(type, payload) when type in @varint_types, do: walk_packed_varints(payload)

  defp packed_payload(type, payload) when type in @fixed32_types,
    do: if(rem(byte_size(payload), 4) == 0, do: :ok, else: {:error, :poison})

  defp packed_payload(type, payload) when type in @fixed64_types,
    do: if(rem(byte_size(payload), 8) == 0, do: :ok, else: {:error, :poison})

  # bytes/string/unknown: opaque by design.
  defp packed_payload(_type, _payload), do: :ok

  defp walk_packed_varints(<<>>), do: :ok

  defp walk_packed_varints(bin) do
    case take_varint(bin) do
      {_value, rest} -> walk_packed_varints(rest)
      :error -> {:error, :poison}
    end
  end

  defp field_props(%{field_props: fps}, field) when is_map(fps), do: Map.get(fps, field)
  defp field_props(_props, _field), do: nil

  # Generated message modules expose __message_props__/0. A module that is not loaded is TRANSIENT
  # (:not_ready); one that is loaded but is an enum / non-protobuf / raises is a codegen defect
  # (:systemic). Neither is ever poison.
  defp message_props(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__message_props__, 0) do
      case mod.__message_props__() do
        %{enum?: true} -> {:error, :systemic}
        %{field_props: fps} = props when is_map(fps) -> {:ok, props}
        _ -> {:error, :systemic}
      end
    else
      not_ready_or_systemic(mod)
    end
  rescue
    # Metadata that raises is a codegen/deployment defect, not bad bytes.
    _ -> {:error, :systemic}
  catch
    # A THROW or EXIT from schema metadata escapes `rescue` entirely; without this the "total"
    # contract is false and a metadata defect would crash the decode boundary it protects.
    _kind, _reason -> {:error, :systemic}
  end

  # An edge-namespace schema that is simply not deployed yet is TRANSIENT; anything else named as a
  # message module but absent is a wiring defect.
  defp not_ready_or_systemic(mod) do
    if Code.ensure_loaded?(mod), do: {:error, :systemic}, else: {:error, :not_ready}
  end
end
