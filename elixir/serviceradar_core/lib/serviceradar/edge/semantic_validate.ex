defmodule ServiceRadar.Edge.SemanticValidate do
  @moduledoc """
  Go-parity SEMANTIC validation of DECODED edge structs (task 1.5), and the stage-aware disposition
  it resolves to.

  This is the second half of the two-layer parity mechanism:

    1. `ServiceRadar.Edge.WireValidate` -- STRUCTURAL: would Go's wire parser reject these bytes?
       It makes no value judgement, because a raw walk cannot reproduce protobuf's effective-value
       semantics (last-one-wins, oneof resolution, embedded-message merging).
    2. THIS module -- SEMANTIC: run on the struct the real decoder produced, where the effective
       value is already resolved, exactly as Go runs `knownTrafficClass`/`knownRouteProfile`/...
       after `proto.Unmarshal`.

  ## Two complementary checks

  `scripts/patch_edge_enum_negatives.exs` makes EVERY edge enum retain an unknown/negative integer
  instead of raising, matching Go. That retention is only safe if NOTHING retained can be admitted,
  so this module applies both:

    * a RECURSIVE RETAINED-VALUE GATE over the whole decoded message graph. After the transform a
      known member always surfaces as its ATOM and a retained non-member always surfaces as a raw
      INTEGER, so "any enum-typed field holding an integer" is exactly "a retained non-member" --
      at any depth, in oneof members, repeated fields, and map values. This covers every patched
      enum USED BY A REACHABLE MESSAGE FIELD (the pinned inventory in
      `scripts/patch_edge_enum_negatives.exs`, not a fixed count). It does NOT cover
      `MtrCompletionDisposition`, which types no message field at all -- it is a value in the
      MTR completion LEAF BYTE GRAMMAR, so its closed set is policed by
      `ServiceRadar.Edge.HashGrammar` before the number is hashed, not here. The gate covers
      enums with no field-specific rule of their own (compression, origin kind,
      nested production/source claim enums, sweep/MTR domain enums, and the recovery
      unattributable reason).
    * the FIELD-SPECIFIC allowed sets Go applies on top (`knownPayloadFamily`/`knownRouteProfile`/
      `knownTrafficClass`/`knownSourceAuthKind`), which additionally reject KNOWN atoms that are not
      permitted -- notably `UNSPECIFIED`, which Go's switches exclude.

  A failure names the PATH to the offending field (e.g.
  `[:production_capability, :production, :traffic_class]`) so the reject audit is actionable.

  ## Dispositions are STAGE-specific

    * `:lane_open` -- the handshake has NO spool/sequence, so there is NO per-delivery slot to
      resolve. The lane is CLOSED and NO `EdgeDeliveryAckV1` disposition is emitted.
    * `:delivery` at a KNOWN slot -- the frame's authenticated lane/sequence coordinates are
      recoverable, so the sequence RESOLVES as `REJECTED_PERMANENT` (reject-audit DLQ). Semantic /
      protocol invalidity is a PERMANENT rejection, never quarantine: quarantine is reserved for
      admitted WIRE poison.
  """

  alias Serviceradar.Edge.V1.CompiledSweepAssignmentV1
  alias Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1
  alias Serviceradar.Edge.V1.EdgeCollectionClaimsV1
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordV1

  # FROZEN allowed-member sets, mirroring Go's CLOSED switches member-for-member. They are written
  # out explicitly, NOT derived from the generated enum module: deriving "every nonzero member" would
  # AUTO-ADMIT any future declared member while Go's closed `known*` switches keep rejecting it until
  # deliberately updated -- the opposite of an evolution guard. `SemanticValidateTest` fails if an
  # enum module gains a member absent from the corresponding frozen set, forcing that decision.
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.MtrTraceEventV1
  alias Serviceradar.Edge.V1.SweepTestV1

  @route_profile [
    :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
    :EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1,
    :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
  ]
  @traffic_class [:EDGE_RECORD_TRAFFIC_CLASS_BULK, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE]
  @origin_kind [:EDGE_ORIGIN_KIND_AGENT, :EDGE_ORIGIN_KIND_CLUSTER_SERVICE]
  @compression [:EDGE_RECORD_COMPRESSION_NONE, :EDGE_RECORD_COMPRESSION_ZSTD]
  @payload_family [
    :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
    :EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1,
    :EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1,
    :EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_TERMINAL_V1,
    :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
  ]
  @source_auth_kind [
    :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
    :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
    :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
    :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
    :EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND,
    :EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN,
    :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
  ]
  # Frozen v1 accepted SET for recovery classification spans (1.6a). NOT "any declared
  # member": a member added by a later proto revision must not begin hashing under an
  # unchanged RecoveryDigestVersion. The reserved numbers 1 (SEGMENT_CORRUPT) and 5
  # (COARSENED) are absent because they were retired before first use.
  @unattributable_reason [
    :EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING,
    :EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
    :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL,
    :EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED,
    :EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE
  ]
  @disposition_kind [
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
    :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT,
    :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
  ]
  # Domain (payload-family) sets: `knownSweepSource`, `knownLifecycleKind`, `knownTransportProtocol`,
  # `mtrTerminalOutcome`, `sweepModeOutcomeKnown` (closed SUCCESS..UNKNOWN range), and the SweepMode
  # switch arms.
  @sweep_source [
    :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
    :SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE,
    :SWEEP_EXECUTION_SOURCE_AD_HOC,
    :SWEEP_EXECUTION_SOURCE_ON_DEMAND,
    :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
  ]
  @lifecycle_kind [
    :SWEEP_EXECUTION_EVENT_KIND_START,
    :SWEEP_EXECUTION_EVENT_KIND_PROGRESS,
    :SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
    :SWEEP_EXECUTION_EVENT_KIND_ABORTED
  ]
  # The scheduler-authored assignment states. UNSPECIFIED is excluded exactly as every
  # other policy excludes it: an unset enum is not a state.
  @assignment_state [
    :SWEEP_ASSIGNMENT_STATE_OPEN,
    :SWEEP_ASSIGNMENT_STATE_COMPLETED,
    :SWEEP_ASSIGNMENT_STATE_ABORTED,
    :SWEEP_ASSIGNMENT_STATE_LOST,
    :SWEEP_ASSIGNMENT_STATE_EXPIRED,
    :SWEEP_ASSIGNMENT_STATE_SUPERSEDED
  ]
  # ENUM ADMISSION only: is this a declared purpose? That COLLECTION claims REQUIRE the
  # COLLECTION purpose is a SEMANTIC rule enforced where those claims are validated, not
  # a field policy -- a policy admitting exactly one member could never notice the enum
  # growing, which is what the evolution guard exists to catch.
  @capability_purpose [
    :EDGE_CAPABILITY_PURPOSE_PRODUCTION,
    :EDGE_CAPABILITY_PURPOSE_SOURCE,
    :EDGE_CAPABILITY_PURPOSE_DELIVERY,
    :EDGE_CAPABILITY_PURPOSE_COLLECTION,
    :EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION
  ]
  @result_format [:SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1]
  @transport_protocol [
    :TRANSPORT_PROTOCOL_ICMP,
    :TRANSPORT_PROTOCOL_TCP,
    :TRANSPORT_PROTOCOL_UDP
  ]
  @mtr_outcome [
    :MTR_OUTCOME_REACHED,
    :MTR_OUTCOME_TARGET_UNREACHABLE,
    :MTR_OUTCOME_PROBE_FAILED,
    :MTR_OUTCOME_TIMED_OUT,
    :MTR_OUTCOME_NOT_ADMITTED,
    :MTR_OUTCOME_QUARANTINED,
    :MTR_OUTCOME_SCHEDULER_LOST
  ]
  @mode_outcome [
    :SWEEP_MODE_OUTCOME_SUCCESS,
    :SWEEP_MODE_OUTCOME_FAILURE,
    :SWEEP_MODE_OUTCOME_SKIPPED,
    :SWEEP_MODE_OUTCOME_NOT_ADMITTED,
    :SWEEP_MODE_OUTCOME_TIMED_OUT,
    :SWEEP_MODE_OUTCOME_UNKNOWN
  ]
  @sweep_mode [
    :SWEEP_MODE_ICMP,
    :SWEEP_MODE_TCP_SYN,
    :SWEEP_MODE_TCP_CONNECT,
    :SWEEP_MODE_MTR
  ]

  # PER-FIELD policy. Per-FIELD, not per-module, because Go's allowed set genuinely differs by
  # context. Every enum field reachable from ANY supported root -- the record plane AND the domain
  # payload families -- must appear here; `SemanticValidateTest` walks the schemas and fails if one
  # is missing.
  @enum_field_policy %{
    # --- record plane ---
    {Serviceradar.Edge.V1.EdgeProducerContext, :origin_kind} => @origin_kind,
    {EdgeProductionClaimsV1, :origin_kind} => @origin_kind,
    {EdgeProductionClaimsV1, :route_profile} => @route_profile,
    {EdgeProductionClaimsV1, :traffic_class} => @traffic_class,
    {Serviceradar.Edge.V1.EdgeRecordDisposition, :kind} => @disposition_kind,
    {EdgeRecordLaneOpen, :route_profile} => @route_profile,
    {EdgeRecordLaneOpen, :traffic_class} => @traffic_class,
    {EdgeRecordLaneOpenAck, :route_profile} => @route_profile,
    {EdgeRecordLaneOpenAck, :traffic_class} => @traffic_class,
    {EdgeRecordV1, :compression} => @compression,
    {EdgeRecordV1, :payload_family} => @payload_family,
    {EdgeRecordV1, :route_profile} => @route_profile,
    {EdgeRecordV1, :traffic_class} => @traffic_class,
    {Serviceradar.Edge.V1.EdgeSourceAuthorizationV1, :kind} => @source_auth_kind,
    {EdgeSourceClaimsV1, :kind} => @source_auth_kind,
    {EdgeSourceClaimsV1, :origin_kind} => @origin_kind,
    {EdgeSourceClaimsV1, :route_profile} => @route_profile,
    {EdgeSourceClaimsV1, :traffic_class} => @traffic_class,
    # --- recovery classification spans (1.6a) ---
    # The span's source kind reuses @source_auth_kind, the SAME set the record's own
    # source_authorization is policed by, so the two can never diverge.
    {Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1, :kind} => @source_auth_kind,
    {Serviceradar.Edge.V1.EdgeUnattributableV1, :reason} => @unattributable_reason,
    # --- domain payload families ---
    {Serviceradar.Edge.V1.MtrTraceBatchV1, :source} => @sweep_source,
    {MtrTraceEventV1, :outcome} => @mtr_outcome,
    {MtrTraceEventV1, :protocol} => @transport_protocol,
    {CompiledSweepAssignmentV1, :result_format} => @result_format,
    {CompiledSweepAssignmentV1, :traffic_class} => @traffic_class,
    {EdgeCollectionClaimsV1, :purpose} => @capability_purpose,
    {EdgeCollectionClaimsV1, :traffic_class} => @traffic_class,
    {EdgeAssignmentExecutionClaimsV1, :purpose} => @capability_purpose,
    {EdgeAssignmentExecutionClaimsV1, :traffic_class} => @traffic_class,
    {Serviceradar.Edge.V1.SweepAssignmentRecordV1, :state} => @assignment_state,
    {Serviceradar.Edge.V1.SweepExecutionEventV1, :kind} => @lifecycle_kind,
    {Serviceradar.Edge.V1.SweepIcmpSummaryV1, :outcome} => @mode_outcome,
    {Serviceradar.Edge.V1.SweepMtrSummaryV1, :outcome} => @mtr_outcome,
    {Serviceradar.Edge.V1.SweepObservationBatchV1, :source} => @sweep_source,
    {Serviceradar.Edge.V1.SweepTcpSummaryV1, :outcome} => @mode_outcome,
    {SweepTestV1, :mode} => @sweep_mode,
    {SweepTestV1, :protocol} => @transport_protocol
  }

  @doc false
  def enum_field_policy, do: @enum_field_policy

  # Struct keys that are protobuf/runtime bookkeeping rather than declared fields.
  @runtime_struct_keys [:__struct__, :__unknown_fields__]

  # Protobuf's legal map KEY types (floating point, bytes, enums and messages are not permitted).
  @map_key_types [
    :int32,
    :int64,
    :uint32,
    :uint64,
    :sint32,
    :sint64,
    :fixed32,
    :fixed64,
    :sfixed32,
    :sfixed64,
    :bool,
    :string
  ]

  # Derived from the SHARED bound `WireValidate` and the decoder are aligned to, so the three layers
  # cannot drift apart. Exceeding it is its OWN failure, not an enum verdict.
  @max_depth ServiceRadar.Edge.WireValidate.max_message_depth()

  @typedoc """
  A semantic failure names the PATH to the offending field.

    * `:unsupported_enum`     -- a retained non-member (raw integer) or a disallowed member.
    * `:unpoliced_enum_field` -- an enum field with NO policy entry: a coverage gap, failed CLOSED.
    * `:max_depth_exceeded`   -- the message graph is nested past the shared bound.
    * `:schema_unavailable`   -- schema metadata missing/raising: a codegen defect, failed CLOSED.
  """
  @type failure ::
          {:unsupported_enum, [atom()]}
          | {:unpoliced_enum_field, [atom()]}
          | {:max_depth_exceeded, [atom()]}
          | {:schema_unavailable, [atom()]}

  @type outcome :: :ok | {:error, failure()}

  @typedoc """
  The stage-resolved disposition of a semantic outcome.

  DATA failures (invalid customer bytes) resolve terminally; EVALUATOR-READINESS failures (this
  release cannot evaluate the record) MUST NOT:

    * `{:close_lane, failure}` -- a DATA failure on a lane-open. No delivery slot exists, so the
      handshake closes with NO `EdgeDeliveryAckV1` disposition.
    * `{:disposition, :REJECTED_PERMANENT, failure}` -- a DATA failure at a KNOWN delivery slot:
      reject-audit DLQ, the sequence RESOLVES.
    * `{:pause, failure}` -- an evaluator-READINESS failure at ANY stage (missing schema metadata or
      an unpoliced enum field). NO ACK and NO terminal resolution, per the frozen task-1.16 rule for
      `:not_ready`/`:systemic`. Permanently reject-DLQ-ing here would destroy VALID customer data
      because of a deployment/coverage defect on OUR side.
  """
  @type disposition ::
          :ok
          | {:close_lane, failure()}
          | {:disposition, :REJECTED_PERMANENT, failure()}
          | {:pause, failure()}

  # Failures meaning "this release cannot evaluate the record", NOT "the record is invalid".
  @readiness_failures [:unpoliced_enum_field, :schema_unavailable]

  @doc """
  Validates a decoded `EdgeRecordV1`: the recursive retained-value gate over the whole graph, then
  the field-specific sets Go applies.
  """
  @spec validate_record(EdgeRecordV1.t() | struct()) :: outcome()
  def validate_record(%EdgeRecordV1{} = r), do: validate_message(r)
  def validate_record(_), do: {:error, {:unsupported_enum, [:record]}}

  @doc """
  Validates a decoded `EdgeRecordLaneOpen`, mirroring Go's `ValidateLaneOpen` enum checks.
  """
  @spec validate_lane_open(EdgeRecordLaneOpen.t() | struct()) :: outcome()
  def validate_lane_open(%EdgeRecordLaneOpen{} = o), do: validate_message(o)
  def validate_lane_open(_), do: {:error, {:unsupported_enum, [:lane_open]}}

  @doc """
  The RECURSIVE RETAINED-VALUE GATE for ANY decoded edge message.

  Walks the whole message graph and rejects any enum-typed field holding a raw INTEGER -- which,
  after the negative-retention transform, is exactly a value with no known member. Use this for
  domain messages (sweep, MTR, plan, recovery) that have no field-specific rule of their own.
  """
  @spec validate_message(struct()) :: outcome()
  def validate_message(message) do
    scan(message, [], 0)
  rescue
    # MALFORMED schema metadata -- a FieldProps/oneof shape the walk does not expect -- would
    # otherwise escape as a raw exception (e.g. FunctionClauseError from field_value/3), which is
    # exactly the codegen/metadata drift the readiness classification claims to CONTAIN. Any escape
    # is a schema defect, so it becomes the typed readiness outcome and PAUSES rather than resolving.
    _ -> {:error, {:schema_unavailable, []}}
  catch
    _kind, _reason -> {:error, {:schema_unavailable, []}}
  end

  @doc """
  Resolves a semantic outcome to its STAGE-specific disposition.

  A READINESS failure pauses at EVERY stage. Otherwise `:lane_open` closes the handshake with no
  disposition, and `:delivery` at a known slot resolves the sequence as `REJECTED_PERMANENT`.
  """
  @spec disposition(outcome(), :lane_open | :delivery) :: disposition()
  def disposition(:ok, _stage), do: :ok

  def disposition({:error, {kind, _path} = failure}, _stage) when kind in @readiness_failures,
    do: {:pause, failure}

  def disposition({:error, failure}, :lane_open), do: {:close_lane, failure}

  def disposition({:error, failure}, :delivery), do: {:disposition, :REJECTED_PERMANENT, failure}

  # ---- recursive retained-value gate ------------------------------------------------------------

  defp scan(_message, path, depth) when depth >= @max_depth,
    do: {:error, {:max_depth_exceeded, Enum.reverse(path)}}

  defp scan(%_{} = message, path, depth) do
    case schema(message.__struct__) do
      {:ok, props} ->
        scan_fields(
          Map.values(props.field_props),
          message,
          props,
          path,
          depth,
          message.__struct__
        )

      # A struct whose schema metadata is missing or raising cannot be proven clean. The public
      # recursive gate must not be fail-open on codegen drift just because raw ingress happens to be
      # protected by WireValidate.
      :error ->
        {:error, {:schema_unavailable, Enum.reverse(path)}}
    end
  end

  defp scan(_other, _path, _depth), do: :ok

  defp scan_fields([], _message, _props, _path, _depth, _mod), do: :ok

  defp scan_fields([fprops | rest], message, props, path, depth, mod) do
    case scan_field(fprops, message, props, path, depth, mod) do
      :ok -> scan_fields(rest, message, props, path, depth, mod)
      {:error, _} = err -> err
    end
  end

  defp scan_field(fprops, message, props, path, depth, mod) do
    # No per-field shape checks here: `schema/1` has already proven the WHOLE module congruent
    # (every dispatch flag present and typed, every storage key real, every oneof entry declared),
    # so this hot path only reads values.
    case field_value(fprops, message, props) do
      :absent -> :ok
      :schema_error -> {:error, {:schema_unavailable, Enum.reverse([fprops.name_atom | path])}}
      {:ok, value} -> scan_value(fprops, value, [fprops.name_atom | path], depth, mod)
    end
  end

  # A oneof MEMBER is stored under the ONEOF's name as `{member_atom, value}`, not under its own
  # name -- reading it directly would silently skip every oneof-nested enum.
  defp field_value(%{oneof: nil, name_atom: name}, message, _props) do
    case Map.get(message, name) do
      nil -> :absent
      value -> {:ok, value}
    end
  end

  defp field_value(%{oneof: index, name_atom: name}, message, props) do
    # `Enum.at/2` accepts NEGATIVE indexes (wrapping from the end) and a loose `{name, _}` match
    # ignores the entry's declared index, so both `oneof: -1` and a mismatched index silently
    # resolved to some entry and skipped the field. Require a non-negative integer, fetch exactly,
    # and match the declared index.
    case oneof_entry(props, index) do
      # An index with no matching oneof entry is metadata DRIFT, not an inactive member. Treating it
      # as simply absent silently skips the field (fail-open) instead of surfacing the defect.
      :error ->
        :schema_error

      {:ok, {oneof_name, ^index}} ->
        # The oneof's storage key must actually EXIST on the struct. If it does not, the metadata
        # names a field this message never had: `Map.get/2` returns nil and the member would be
        # read as legitimately inactive, silently skipping a value that IS set.
        if Map.has_key?(message, oneof_name) do
          case Map.get(message, oneof_name) do
            {^name, value} ->
              {:ok, value}

            # A DIFFERENT member is selected: legitimately absent ONLY if that member is actually
            # declared for this oneof index. Otherwise the metadata and the struct disagree.
            {other, _value} ->
              if declared_member?(props, index, other), do: :absent, else: :schema_error

            nil ->
              :absent

            _ ->
              :schema_error
          end
        else
          :schema_error
        end

      _ ->
        :schema_error
    end
  end

  defp valid_oneof_index?(nil), do: true
  defp valid_oneof_index?(i) when is_integer(i) and i >= 0, do: true
  defp valid_oneof_index?(_), do: false

  # True when `member` is declared as a field of the oneof at `index`.
  defp declared_member?(%{field_props: fps}, index, member) when is_map(fps) do
    Enum.any?(fps, fn {_tag, fp} ->
      Map.get(fp, :oneof) == index and Map.get(fp, :name_atom) == member
    end)
  end

  defp declared_member?(_props, _index, _member), do: false

  defp oneof_entry(%{oneof: oneofs}, index)
       when is_list(oneofs) and is_integer(index) and index >= 0,
       do: Enum.fetch(oneofs, index)

  defp oneof_entry(_props, _index), do: :error

  # Container dispatch is MUTUALLY EXCLUSIVE and TOTAL. Previously the child type was established
  # only after a container guard, so when the guard failed the generic embedded clause reinterpreted
  # the field as singular and a wrong-shaped container passed as valid.
  defp scan_value(%{enum?: true, repeated?: true} = fprops, value, path, _depth, mod)
       when is_list(value),
       do: check_enum_values(value, fprops, path, mod)

  # A repeated enum MUST be a list. `List.wrap/1` silently normalised a single bare value.
  defp scan_value(%{enum?: true, repeated?: true}, _value, path, _depth, _mod),
    do: {:error, {:schema_unavailable, Enum.reverse(path)}}

  defp scan_value(%{enum?: true} = fprops, value, path, _depth, mod),
    do: check_enum_values([value], fprops, path, mod)

  # A map field must be a PLAIN map. `is_map/1` also matches structs, so a single %Entry{} passed.
  defp scan_value(%{embedded?: true, map?: true, type: entry_mod}, value, path, depth, _mod)
       when is_map(value) and not is_struct(value) do
    case map_value_field(entry_mod) do
      {:enum, value_fprops} -> check_enum_values(Map.values(value), value_fprops, path, entry_mod)
      {:message, child} -> scan_each(Map.values(value), child, path, depth)
      :scalar -> :ok
      :error -> {:error, {:schema_unavailable, Enum.reverse(path)}}
    end
  end

  defp scan_value(%{embedded?: true, map?: true}, _value, path, _depth, _mod),
    do: {:error, {:schema_unavailable, Enum.reverse(path)}}

  defp scan_value(%{embedded?: true, repeated?: true, type: child}, value, path, depth, _mod)
       when is_list(value),
       do: scan_each(value, child, path, depth)

  # A repeated embedded field must be a LIST; a single %Child{} is a shape defect, not a value.
  defp scan_value(%{embedded?: true, repeated?: true}, _value, path, _depth, _mod),
    do: {:error, {:schema_unavailable, Enum.reverse(path)}}

  # SINGULAR embedded: explicitly not repeated and not a map, so this can never absorb a container.
  defp scan_value(
         %{embedded?: true, repeated?: false, map?: false, type: child},
         value,
         path,
         depth,
         _mod
       ),
       do: scan_typed(value, child, path, depth)

  defp scan_value(%{embedded?: true}, _value, path, _depth, _mod),
    do: {:error, {:schema_unavailable, Enum.reverse(path)}}

  defp scan_value(_fprops, _value, _path, _depth, _mod), do: :ok

  # A declared embedded value MUST be a struct of its declared message type. Anything else (a bare
  # integer selected into a oneof, a wrong struct) falls through `scan/3`'s catch-all and is skipped,
  # so it is drift, not data to accept.
  defp scan_typed(value, child, path, depth) do
    if is_struct(value, child) do
      scan(value, path, depth + 1)
    else
      {:error, {:schema_unavailable, Enum.reverse(path)}}
    end
  end

  # After the negative-retention transform a KNOWN member is an ATOM and a RETAINED non-member is a
  # raw INTEGER, so an integer is precisely a value Go would retain and then reject. A member atom is
  # then checked against this FIELD's policy; a field with no policy entry is a coverage gap and
  # fails CLOSED rather than being waved through.
  defp check_enum_values(values, fprops, path, mod) do
    # A raw INTEGER is a retained non-member (the transform keeps Go's integer instead of raising).
    if Enum.any?(values, &is_integer/1) do
      {:error, {:unsupported_enum, Enum.reverse(path)}}
    else
      case Map.fetch(@enum_field_policy, {mod, fprops.name_atom}) do
        {:ok, allowed} ->
          if Enum.all?(values, &(&1 in allowed)) do
            :ok
          else
            {:error, {:unsupported_enum, Enum.reverse(path)}}
          end

        # No policy for this field: a COVERAGE GAP in this release, not bad customer data. It is an
        # evaluator-readiness failure, so `disposition/2` must NOT resolve it permanently.
        :error ->
          {:error, {:unpoliced_enum_field, Enum.reverse(path)}}
      end
    end
  end

  # For a map field, classify the Entry's VALUE field (tag 2).
  defp scan_each([], _child, _path, _depth), do: :ok

  defp scan_each([item | rest], child, path, depth) do
    case scan_typed(item, child, path, depth) do
      :ok -> scan_each(rest, child, path, depth)
      {:error, _} = err -> err
    end
  end

  # Consumes only VALIDATED Entry metadata: `schema/1` applies the full local congruence (and its
  # freshness keying), so the flags this dispatches on have been proven to agree with the types.
  defp map_value_field(entry_mod) do
    case schema(entry_mod) do
      {:ok, %{field_props: fps}} ->
        case Map.get(fps, 2) do
          %{enum?: true} = fp -> {:enum, fp}
          %{embedded?: true, type: child} when is_atom(child) -> {:message, child}
          %{} -> :scalar
          _ -> :error
        end

      :error ->
        :error
    end
  end

  # ---- schema congruence preflight (a cycle-aware GRAPH check, cached per module binary) --------
  #
  # Metadata drift does not have to RAISE to be dangerous. A FieldProps that merely LOOKS wrong -- a
  # missing dispatch flag, a `type` disagreeing with those flags, a storage key that is not on the
  # struct, a struct key no metadata describes, an unloadable child module -- makes the walk miss its
  # typed clauses and silently SKIP the field, so a retained non-member enum sails through.
  #
  # The model is LOCAL congruence plus VALUE-DRIVEN child validation, NOT an eager whole-graph
  # traversal: each module's own metadata is proven internally consistent (and its referenced modules
  # proven to load and be of the right kind) before any of its values are read, and a CHILD's full
  # congruence is established when `scan/3` actually descends into a child value. That deliberately
  # avoids traversing branches a given record never populates, and keeps the verdict live rather than
  # frozen at first use.
  # The verdict is this module's LOCAL congruence. It is recomputed on every call, deliberately.
  #
  # A `:persistent_term` cache lived here and was removed: its key was derived from a LIVE read of
  # the module (own MD5 plus a direct-dependency fingerprint), and the recompute path then reread
  # that module independently. A hot replacement landing between those two reads published the NEW
  # module's props under the OLD module's key, so a rollback to the original binary was served an
  # empty schema and ADMITTED retained invalid enum values. Rechecking the target module's MD5
  # after the fact does not close it -- that covers neither a dependency change nor ABA replacement
  # of the same-length binary.
  #
  # Recomputation is cheap and non-recursive: it inspects one module's own metadata and fails fast.
  # `scan/3` still descends into real child VALUES and consults each child's own current verdict, so
  # the graph guarantee stays live rather than frozen at first use.
  defp schema(mod) do
    compute_schema(mod)
  end

  defp compute_schema(mod) do
    case validate_module(mod) do
      {:ok, props} -> {:ok, props}
      _ -> :error
    end
  end

  # LOCAL congruence only: this module's own metadata must be internally consistent and every module
  # it references must LOAD and be of the right kind. It deliberately does not recurse into a child's
  # full graph -- that is established when `scan/3` actually descends into a child value, using the
  # child's own freshly-keyed verdict.
  defp validate_module(mod) do
    with {:ok, props} <- raw_props(mod),
         {:ok, blank} <- blank_struct(mod),
         :ok <- storage_congruent(props, blank),
         :ok <- oneofs_congruent(props, blank),
         :ok <- fields_congruent(props, blank) do
      {:ok, props}
    else
      _ -> :error
    end
  end

  # A referenced MESSAGE module must load and expose message metadata. Its deep congruence is
  # checked when a value of that type is actually walked.
  defp message_module?(mod) do
    match?({:ok, _props}, raw_props(mod))
  end

  defp raw_props(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__message_props__, 0) do
      case mod.__message_props__() do
        %{enum?: true} ->
          :error

        %{field_props: fps, oneof: oneofs} = props when is_map(fps) and is_list(oneofs) ->
          {:ok, props}

        %{field_props: fps} = props when is_map(fps) ->
          {:ok, Map.put(props, :oneof, [])}

        _ ->
          :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp blank_struct(mod) do
    {:ok, struct(mod)}
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  # TWO-WAY storage congruence: every metadata field must have storage AND every storage key must be
  # described by metadata. A one-way check misses a struct field no `field_props` entry mentions --
  # never visited, so a retained value there is never validated.
  defp storage_congruent(%{field_props: fps, oneof: oneofs}, blank)
       when is_map(fps) and is_list(oneofs) do
    actual =
      blank
      |> Map.keys()
      |> Enum.reject(&(&1 in @runtime_struct_keys))
      |> MapSet.new()

    ordinary = for {_tag, fp} <- fps, is_nil(Map.get(fp, :oneof)), do: Map.get(fp, :name_atom)
    oneof_names = for {name, _idx} <- oneofs, do: name

    if MapSet.equal?(actual, MapSet.new(ordinary ++ oneof_names)), do: :ok, else: :error
  end

  defp storage_congruent(_props, _blank), do: :error

  defp fields_congruent(%{field_props: fps} = props, blank) do
    Enum.reduce_while(Map.values(fps), :ok, fn fp, _acc ->
      if congruent_field?(fp, props, blank), do: {:cont, :ok}, else: {:halt, :error}
    end)
  end

  defp congruent_field?(%{} = fp, props, blank) do
    name = Map.get(fp, :name_atom)

    with true <- is_atom(name) and not is_nil(name),
         true <- is_boolean(Map.get(fp, :enum?)),
         true <- is_boolean(Map.get(fp, :embedded?)),
         true <- is_boolean(Map.get(fp, :repeated?)),
         true <- is_boolean(Map.get(fp, :map?)),
         true <- valid_oneof_index?(Map.get(fp, :oneof)),
         true <- Map.has_key?(fp, :type),
         true <- coherent_type?(fp),
         true <- storage_present?(fp, name, props, blank) do
      true
    else
      _ -> false
    end
  end

  defp congruent_field?(_fp, _props, _blank), do: false

  # `type` must AGREE with the dispatch flags, and every referenced module must be REAL. The check is
  # driven by the TYPE, not by the flags: a flag-driven check can never notice a `{:enum, _}` type
  # whose `enum?` is false, because it never reaches the enum clause at all.
  defp coherent_type?(%{type: {:enum, enum_mod}} = fp) when is_atom(enum_mod) do
    not is_nil(enum_mod) and Map.get(fp, :enum?) == true and Map.get(fp, :embedded?) == false and
      Map.get(fp, :map?) == false and enum_module?(enum_mod)
  end

  defp coherent_type?(%{type: type} = fp) when is_atom(type) do
    cond do
      is_nil(type) ->
        false

      module_atom?(type) ->
        Map.get(fp, :embedded?) == true and Map.get(fp, :enum?) == false and
          message_module?(type) and (Map.get(fp, :map?) != true or map_entry_ok?(type))

      true ->
        Map.get(fp, :enum?) == false and Map.get(fp, :embedded?) == false and
          Map.get(fp, :map?) == false
    end
  end

  defp coherent_type?(_fp), do: false

  defp module_atom?(a) when is_atom(a), do: String.starts_with?(Atom.to_string(a), "Elixir.")
  defp module_atom?(_), do: false

  # A referenced ENUM module must load and actually BE an enum.
  defp enum_module?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__message_props__, 0) and
      match?(%{enum?: true}, mod.__message_props__())
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  # Protobuf forbids a map whose VALUE is another map. Rejecting `map?: true` on an Entry value is
  # both correct and what guarantees TERMINATION: a self-referential Entry would otherwise recurse
  # forever through coherent_type?/map_entry_ok?, and no rescue/catch can contain nontermination.
  # The Entry itself then runs through the SAME local congruence routine (`validate_module/1`) as
  # any other message, not a tag-2-only subset.
  defp map_entry_ok?(entry_mod) do
    case raw_props(entry_mod) do
      {:ok, %{field_props: fps} = props} ->
        # A generated protobuf map Entry carries the message-level `map?: true` marker and the
        # canonical shape: exactly tags 1 (key) and 2 (value), no oneof, a legal protobuf map KEY
        # type, and a value that is not itself a map (protobuf forbids map-of-map -- which is also
        # what bounds this recursion).
        key_fp = Map.get(fps, 1)
        value_fp = Map.get(fps, 2)

        shell_ok =
          Map.get(props, :map?) == true and
            MapSet.equal?(MapSet.new(Map.keys(fps)), MapSet.new([1, 2])) and
            Map.get(props, :oneof, []) == [] and
            is_map(key_fp) and Map.get(key_fp, :type) in @map_key_types and
            is_map(value_fp) and Map.get(value_fp, :map?) != true

        # The SHELL alone is not enough: `map_value_field/1` dispatches on the Entry's tag-2 FLAGS,
        # so an Entry whose value declares `type: {:enum, _}` but `enum?: false` would be classified
        # scalar and its retained integer skipped. The Entry therefore runs through the SAME local
        # congruence routine (`validate_module/1`) as any other message before it is trusted.
        shell_ok and match?({:ok, _props}, validate_module(entry_mod))

      :error ->
        false
    end
  end

  # Every field must be READABLE: an ordinary field's storage key, or its oneof's storage key, has to
  # exist on the struct. Without this a missing key reads as `nil` and the field is skipped.
  defp storage_present?(%{oneof: nil}, name, _props, blank), do: Map.has_key?(blank, name)

  defp storage_present?(%{oneof: index}, _name, props, blank) do
    case oneof_entry(props, index) do
      {:ok, {oneof_name, ^index}} -> is_atom(oneof_name) and Map.has_key?(blank, oneof_name)
      _ -> false
    end
  end

  # Every DECLARED oneof entry must have a real storage key and at least one member field. An entry
  # with no member is never iterated (validation walks `field_props`), so a populated orphan oneof
  # would never be inspected at all.
  defp oneofs_congruent(%{oneof: oneofs, field_props: fps}, blank) when is_list(oneofs) do
    Enum.reduce_while(Enum.with_index(oneofs), :ok, fn {entry, index}, _acc ->
      with {name, ^index} <- entry,
           true <- is_atom(name) and not is_nil(name),
           true <- Map.has_key?(blank, name),
           true <- Enum.any?(fps, fn {_t, fp} -> Map.get(fp, :oneof) == index end) do
        {:cont, :ok}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp oneofs_congruent(_props, _blank), do: :error
end
