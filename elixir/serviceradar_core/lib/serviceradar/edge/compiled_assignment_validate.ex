defmodule ServiceRadar.Edge.CompiledAssignmentValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.ValidateCompiledSweepAssignment` and
  `ValidateAssignmentAgainstCompiled` (task 1.3). The execution-grant claim validation is
  NOT peered here -- see the scope section below.

  `HashGrammar` reproduces the two compiled-assignment digests and `ClaimsFraming`
  reproduces the signing preimages, so the GRAMMARS already agree across runtimes.
  This module validates the CARRIER: without it a carrier Go rejects -- a zero config
  generation, an unknown result format, a claim bound to a different carrier -- decoded
  cleanly and returned `:ok` from every Elixir entry point.

  ## SCOPE: the carrier only

  It does NOT validate an ASSIGNMENT_EXECUTION grant. Go's `validateExecutionGrantClaims`
  has no peer here yet: the grant's own received-byte ceiling, its envelope-containment
  rule and its full claim interpretation are still Go-only, so this module SHALL NOT be
  described as carrier-and-grant parity.

  ## What this module does NOT do

  It does not VERIFY a signature and it does not AUTHORIZE collection. Those need key
  material and a trust resolver, and conflating them is the defect the Go review kept
  finding: a carrier that passes here is well-formed and self-consistent, never
  attested and never permission to run anything.

  Nor does it own the physical byte ceiling. `validate_bytes/1` bounds the RECEIVED
  bytes before decoding, because a decoded struct cannot establish that -- a carrier
  with duplicate known fields collapses on decode and reaches a struct-level check
  looking compliant.

  ## Reasons are TYPED

  A shared reject vector asserts WHY a carrier was refused, not merely that it was.
  The reasons correspond to the Go errors, with the same deliberate layering
  difference the other validators have: through `validate_bytes/1`, ENUM ADMISSION
  runs first, so an undeclared enum surfaces as `{:unsupported_enum, [...]}` rather
  than the semantic reason underneath. Both refuse the carrier; only the layer that
  speaks first differs, and the vectors assert the layered reason rather than
  pretending otherwise.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.CompiledSweepAssignmentV1
  alias ServiceRadar.Edge.WireDecode

  @digest_version 1
  @sha256_bytes 32

  # ENUM ADMISSION (is this a DECLARED member?) belongs to `SemanticValidate`, which
  # polices every enum field reachable from the carrier. What lives here is the SEMANTIC
  # rule: a carrier requires EDGE_RECORDS_V1 specifically, which is narrower than
  # admission and must not be expressed as a field policy -- a policy admitting exactly
  # one member could never notice the enum growing.
  @traffic_classes [:EDGE_RECORD_TRAFFIC_CLASS_BULK, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE]

  @typedoc """
  Every reason this module can return.

  It is the UNION of FOUR sources, and the delegated ones are REFERENCED rather than copied:
  a hand-copied list drifts the moment a delegate grows a reason, and a caller matching
  exhaustively then crashes on a shape the contract said could not occur.

    * this module's own semantic reasons;
    * `WireDecode.reason/0`;
    * `SemanticValidate.failure/0` in full -- enum admission returns FOUR shapes, and only
      `:unsupported_enum` had been declared;
    * `CapabilitySigning.reason/0`, since that validator is delegated to rather than
      re-implemented.
  """
  @type reason ::
          :identity
          | :unknown_fields
          | :digest_mismatch
          | :binding
          | :lease
          | :capability
          | WireDecode.reason()
          | SemanticValidate.failure()
          | CapabilitySigning.reason()

  @doc """
  Bounds the RECEIVED bytes, decodes, runs enum admission, then validates.

  This is the authoritative entry point for a carrier that arrived as a standalone
  artifact. A caller holding only a decoded struct has already lost the bytes the
  ceiling is measured against.

  Accepts `term()`, not `binary()`: a non-binary is DELIBERATELY handled -- the curated
  decoder classifies it `:systemic`, a caller fault that must never become permanent
  quarantine. A `binary()` spec would have made that documented behaviour unreachable
  according to the contract, and Dialyzer would call the totality test dead code.
  """
  @spec validate_bytes(term()) :: {:ok, struct()} | {:error, reason()}
  def validate_bytes(bytes) do
    with {:ok, carrier} <- WireDecode.decode_compiled_assignment(bytes),
         :ok <- admit_enums(carrier),
         :ok <- validate(carrier) do
      {:ok, carrier}
    end
  end

  @doc """
  Validates ONE decoded carrier: identity, every compiled fact's domain, its self
  digests, and the scheduler attestation's binding to it.

  Total: a shape this never saw still returns `{:error, reason}` rather than raising.
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(%CompiledSweepAssignmentV1{} = c) do
    with :ok <- no_unknown_fields(c),
         :ok <- structure(c),
         :ok <- body_digest(c),
         :ok <- collection_capability(c) do
      artifact_digest(c)
    end
  end

  # A PLAIN MAP is refused. Protobuf decoding always yields the struct, so a map reached this
  # by skipping the wire layer entirely -- where retained unknown fields and wire-hygiene
  # violations live. Accepting one let a hand-built value claim a validated carrier's status.
  def validate(_), do: {:error, :identity}

  # Retained unknown fields sit OUTSIDE the field-framed digests, so a later reader could
  # reinterpret bytes the content address never covered. Go rejects them recursively before
  # trusting any field; this is the top-level peer for a decoded struct. (The RAW path already
  # rejects the wire forms protobuf-elixir erases -- see WireDecode.)
  defp no_unknown_fields(c) do
    if Map.get(c, :__unknown_fields__, []) == [], do: :ok, else: {:error, :unknown_fields}
  end

  @doc """
  Proves the record/carrier RELATION. Each is validated on its own terms first, then
  every fact they BOTH carry must agree -- otherwise a valid record could reference a
  valid carrier describing a different plan, range, scope, agent, shard or epoch.

  Collection is constrained to the LEASE: the carrier's window must not extend past
  the lease of the record referencing it. The two are otherwise unrelated quantities,
  so a carrier authorised to 200 attached to a record whose lease lapses at 2 would
  let an agent keep collecting long after the fence it holds expired.
  """
  @spec validate_against_record(term(), term()) :: :ok | {:error, term()}
  def validate_against_record(r, c) when is_map(r) and is_map(c) do
    with :ok <- ServiceRadar.Edge.AssignmentValidate.validate(r),
         :ok <- validate(c),
         :ok <- reference_binds(r, c),
         :ok <- shared_facts_agree(r, c) do
      lease_covers(r, c)
    end
  end

  def validate_against_record(_, _), do: {:error, :identity}

  # --- structure -------------------------------------------------------------

  defp structure(c) do
    # The SPECIFIC attempt. Without these the carrier describes a
    # (plan, range, shard, epoch) TUPLE that several attempts can share.
    # config_generation starts at 1: 0 is the proto default, so accepting it
    # would let an unset field pose as the first generation.
    # A validity window that is empty or inverted constrains nothing.
    if uuidv7?(get(c, :compiled_assignment_id)) and
         get(c, :digest_version) == @digest_version and
         uuid?(get(c, :producer_assignment_id)) and uuid?(get(c, :execution_id)) and
         uuidv7?(get(c, :execution_plan_id)) and
         uuid?(get(c, :target_range_id)) and uuid?(get(c, :network_scope_id)) and
         uuid?(get(c, :authenticated_agent_id)) and
         digest32?(get(c, :execution_plan_sha256)) and
         digest32?(get(c, :target_range_sha256)) and
         digest32?(get(c, :check_set_sha256)) and
         uint32?(get(c, :execution_shard)) and uint64?(get(c, :assignment_epoch)) and
         uint64?(get(c, :config_generation)) and get(c, :config_generation) > 0 and
         get(c, :result_format) == :SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1 and
         get(c, :traffic_class) in @traffic_classes and
         pos_int64?(get(c, :not_before_unix_nano)) and
         int64?(get(c, :expires_at_unix_nano)) and
         get(c, :expires_at_unix_nano) > get(c, :not_before_unix_nano) do
      :ok
    else
      {:error, :identity}
    end
  end

  # --- digests ---------------------------------------------------------------

  defp body_digest(c) do
    want = get(c, :compiled_assignment_body_sha256)

    if digest32?(want) and want == HashGrammar.compiled_assignment_body_digest(c),
      do: :ok,
      else: {:error, :digest_mismatch}
  end

  # Checked LAST, because it covers the capability: it is only meaningful once that
  # capability has been validated.
  defp artifact_digest(c) do
    want = get(c, :compiled_assignment_sha256)

    if digest32?(want) and want == HashGrammar.compiled_assignment_artifact_digest(c),
      do: :ok,
      else: {:error, :digest_mismatch}
  end

  # --- the scheduler attestation --------------------------------------------

  defp collection_capability(c) do
    cap = get(c, :collection_capability)

    if cap == nil do
      # An unattested carrier is a set of facts nobody stands behind.
      {:error, :capability}
    else
      # The SHARED capability validator, not a local re-implementation. It owns unknown-field
      # rejection, the known version and algorithm sets, issuer presence, envelope-window
      # validity, purpose-matches-variant and signature presence. Hand-rolling only the
      # purpose check here left every one of those unchecked on a carrier's attestation --
      # the same bypass the Go review found, in the peer.
      with :ok <- CapabilitySigning.validate(cap, :collection) do
        {:collection, claims} = Map.get(cap, :claims)
        capability_window_and_binding(c, cap, claims)
      end
    end
  end

  defp capability_window_and_binding(c, cap, claims) do
    cond do
      # The enum field must agree with the VARIANT. CapabilitySigning derives purpose from
      # the variant; this catches a claims body whose own purpose field says otherwise.
      Map.get(claims, :purpose) != :EDGE_CAPABILITY_PURPOSE_COLLECTION ->
        {:error, :capability}

      not pos_int64?(Map.get(cap, :not_before_unix_nano)) ->
        {:error, :capability}

      # The attestation MUST cover the carrier's window. One expiring first would
      # leave the tail of the window unattested while the carrier still claims it.
      Map.get(cap, :not_before_unix_nano) > get(c, :not_before_unix_nano) or
          Map.get(cap, :expires_at_unix_nano) < get(c, :expires_at_unix_nano) ->
        {:error, :capability}

      # The claim binds THIS carrier, by BODY digest, and the same work it describes.
      not claim_binds?(c, claims) ->
        {:error, :capability}

      true ->
        :ok
    end
  end

  defp claim_binds?(c, claims) do
    Map.get(claims, :compiled_assignment_body_sha256) == get(c, :compiled_assignment_body_sha256) and
      Map.get(claims, :producer_assignment_id) == get(c, :producer_assignment_id) and
      Map.get(claims, :execution_id) == get(c, :execution_id) and
      Map.get(claims, :network_scope_id) == get(c, :network_scope_id) and
      Map.get(claims, :authenticated_agent_id) == get(c, :authenticated_agent_id) and
      Map.get(claims, :execution_plan_id) == get(c, :execution_plan_id) and
      Map.get(claims, :target_range_id) == get(c, :target_range_id) and
      Map.get(claims, :execution_shard) == get(c, :execution_shard) and
      Map.get(claims, :assignment_epoch) == get(c, :assignment_epoch) and
      Map.get(claims, :traffic_class) == get(c, :traffic_class)
  end

  # --- the record relation ---------------------------------------------------

  # The reference must name THIS carrier: id AND ARTIFACT digest. An id alone names a
  # carrier without pinning which revision of it was attested.
  defp reference_binds(r, c) do
    if get(r, :compiled_assignment_id) == get(c, :compiled_assignment_id) and
         get(r, :compiled_assignment_sha256) == get(c, :compiled_assignment_sha256),
       do: :ok,
       else: {:error, :binding}
  end

  defp shared_facts_agree(r, c) do
    if get(r, :producer_assignment_id) == get(c, :producer_assignment_id) and
         get(r, :execution_id) == get(c, :execution_id) and
         get(r, :execution_plan_id) == get(c, :execution_plan_id) and
         get(r, :execution_plan_sha256) == get(c, :execution_plan_sha256) and
         get(r, :target_range_id) == get(c, :target_range_id) and
         get(r, :target_range_sha256) == get(c, :target_range_sha256) and
         get(r, :network_scope_id) == get(c, :network_scope_id) and
         get(r, :authenticated_agent_id) == get(c, :authenticated_agent_id) and
         get(r, :execution_shard) == get(c, :execution_shard) and
         get(r, :assignment_epoch) == get(c, :assignment_epoch) and
         get(r, :check_set_sha256) == get(c, :check_set_sha256),
       do: :ok,
       else: {:error, :binding}
  end

  defp lease_covers(r, c) do
    if get(c, :expires_at_unix_nano) <= get(r, :lease_expires_at_unix_nano),
      do: :ok,
      else: {:error, :lease}
  end

  # --- plumbing --------------------------------------------------------------

  defp admit_enums(carrier), do: SemanticValidate.validate_message(carrier)

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp uuid?(v), do: PlanValidate.canonical_uuid?(v)
  defp uuidv7?(v), do: PlanValidate.uuidv7?(v)
  defp digest32?(v), do: is_binary(v) and byte_size(v) == @sha256_bytes
  defp uint32?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFF
  defp uint64?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFFFFFFFFFF
  defp int64?(v), do: is_integer(v) and v >= -0x8000000000000000 and v <= 0x7FFFFFFFFFFFFFFF
  defp pos_int64?(v), do: is_integer(v) and v > 0 and v <= 0x7FFFFFFFFFFFFFFF
end
