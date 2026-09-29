defmodule ServiceRadar.Edge.ExecutionGrantValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.validateExecutionGrantClaims` and the structural half of
  `verifyExecutionGrantSignature` (task 1.3).

  An ASSIGNMENT_EXECUTION grant is a HOST authority's PERMISSION to execute one compiled
  assignment. It is NOT the scheduler's attestation: `CompiledAssignmentValidate` covers
  that, the two are signed by different key families, and neither is inferable from the
  other. Collapsing them would let the scheduler grant itself host permission.

  ## What this module does NOT do

  It does not VERIFY the signature and it does not AUTHORIZE collection -- those need key
  material, a trust resolver, an attested caller and the authoritative record. A grant that
  passes here is well-formed and binds the record and carrier presented with it; it is not
  permission to run anything until the composed boundary says so.

  It also does not enforce FRESHNESS by default, because freshness is a question about an
  instant and this module answers a question about shape. `fresh_at/2` is separate and
  explicit for exactly that reason.

  ## Reasons are TYPED

  As elsewhere, the reason union is composed from the delegates rather than copied, so a
  caller matching exhaustively is not broken when a delegate grows a reason.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.CompiledAssignmentValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias ServiceRadar.Edge.WireDecode

  @sha256_bytes 32
  @traffic_classes [:EDGE_RECORD_TRAFFIC_CLASS_BULK, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE]

  @type reason ::
          :binding
          | :not_fresh
          | WireDecode.reason()
          | SemanticValidate.failure()
          | CapabilitySigning.reason()

  @doc """
  Bounds the RECEIVED grant bytes at 16 KiB, decodes, runs enum admission, then validates the
  grant against the record and carrier.

  `raw_carrier` is BYTES, not a decoded carrier, for the same reason: a decoded carrier has
  already lost the bytes its own 64 KiB ceiling is measured against, so accepting one here
  would reopen the bypass the carrier validator closes.
  """
  @spec validate_bytes(term(), term(), term()) :: {:ok, struct()} | {:error, reason()}
  def validate_bytes(record, raw_carrier, raw_grant) do
    with {:ok, carrier} <- CompiledAssignmentValidate.validate_bytes(raw_carrier),
         :ok <- CompiledAssignmentValidate.validate_against_record(record, carrier),
         {:ok, grant} <- WireDecode.decode_execution_grant(raw_grant),
         :ok <- SemanticValidate.validate_message(grant),
         :ok <- validate(record, carrier, grant) do
      {:ok, grant}
    end
  end

  @doc """
  Validates ONE decoded grant against a record and carrier the caller has already validated.

  The ROLE is derived first, before any claim member is read: deriving purpose only inspects
  which oneof member is set, so it costs nothing to answer first and keeps a wrong-role
  capability reported as exactly that rather than as a malformed claim.
  """
  @spec validate(term(), term(), term()) :: :ok | {:error, reason()}
  def validate(r, c, %EdgeSignedCapabilityV1{} = grant) when is_map(r) and is_map(c) do
    # THE ROLE FIRST. Deriving it only inspects which oneof member is set, so it costs nothing
    # to answer before anything else -- and without it a wrong-role capability that ALSO has a
    # bad version reports :version, which says nothing about the thing actually wrong with it.
    # Go answers the role first for the same reason; this is that ordering, not a restatement
    # of the envelope rules, which stay with the shared validator below.
    with :ok <- role(grant),
         :ok <- CapabilitySigning.validate(grant, :assignment_execution) do
      {:assignment_execution, claims} = grant.claims
      claims(r, c, claims, grant.not_before_unix_nano, grant.expires_at_unix_nano)
    end
  end

  def validate(_, _, _), do: {:error, :capability}

  @doc """
  The CURRENT freshness check, deliberately separate from shape.

  BOTH windows are checked: the envelope's and the claim's own collection window. Containment
  is enforced when the claim is validated, so the inner window is the narrower by construction
  -- but checking only one would still be wrong, because a caller may hold a grant this module
  never validated.
  """
  @spec fresh_at(term(), integer()) :: :ok | {:error, reason()}
  # The claim body must be the GENERATED STRUCT. `{:assignment_execution, 7}` is a well-formed
  # oneof shape, so a variant-only match succeeded and every field read then raised BadMapError
  # -- a contract promising `{:error, reason}` must not raise on a shape it did not anticipate.
  # fresh_at/2 does not go through the shared validator, so it carries its own type guard.
  def fresh_at(
        %EdgeSignedCapabilityV1{
          claims: {:assignment_execution, %EdgeAssignmentExecutionClaimsV1{} = j}
        } = grant,
        now
      )
      when is_integer(now) do
    if within?(now, grant.not_before_unix_nano, grant.expires_at_unix_nano) and
         within?(now, j.collection_not_before_unix_nano, j.collection_expires_unix_nano),
       do: :ok,
       else: {:error, :not_fresh}
  end

  def fresh_at(_, _), do: {:error, :capability}

  # --- the claim, interpreted IN FULL ---------------------------------------

  defp claims(r, c, j, env_not_before, env_expires) do
    with :ok <- purpose(j),
         :ok <- producer_key(r, j),
         :ok <- production_facts(r, j),
         :ok <- plan_and_range(r, j),
         :ok <- traffic_class(c, j),
         :ok <- collection_window(j, env_not_before, env_expires),
         :ok <- exact_carrier(c, j) do
      source_identity(r, j)
    end
  end

  # The enum field must agree with the VARIANT. CapabilitySigning derives purpose from the
  # variant; this catches a claims body whose own purpose field says otherwise.
  defp purpose(j) do
    if Map.get(j, :purpose) == :EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
      do: :ok,
      else: {:error, :binding}
  end

  # execution_shard / assignment_epoch are the SOLE wire representation of the producer key's
  # run_shard / authority_epoch, so the grant is compared ACROSS that naming rather than
  # expecting duplicate producer-named copies on the record.
  defp producer_key(r, j) do
    if Map.get(j, :network_scope_id) == Map.get(r, :network_scope_id) and
         Map.get(j, :authenticated_agent_id) == Map.get(r, :authenticated_agent_id) and
         Map.get(j, :producer_assignment_id) == Map.get(r, :producer_assignment_id) and
         Map.get(j, :execution_id) == Map.get(r, :execution_id) and
         Map.get(j, :run_id) == Map.get(r, :run_id) and
         Map.get(j, :run_shard) == Map.get(r, :execution_shard) and
         Map.get(j, :authority_epoch) == Map.get(r, :assignment_epoch),
       do: :ok,
       else: {:error, :binding}
  end

  # The three facts NO scheduler carrier covers. Without them a grant would leave the
  # production scope, its digest and the contract bundle free to be anything.
  defp production_facts(r, j) do
    if Map.get(j, :production_scope_id) == Map.get(r, :production_scope_id) and
         Map.get(j, :scope_sha256) == Map.get(r, :scope_sha256) and
         Map.get(j, :contract_bundle_sha256) == Map.get(r, :contract_bundle_sha256),
       do: :ok,
       else: {:error, :binding}
  end

  # REQUIRED lengths, so absence cannot read as "no constraint": these are declared "empty if
  # N/A" on the shared source claim, but a sweep assignment ALWAYS covers one plan and one
  # range. Treating empty as unconstrained let a signed grant naming another range authorize
  # this one.
  defp plan_and_range(r, j) do
    plan = Map.get(j, :execution_plan_sha256)
    range = Map.get(j, :target_range_sha256)

    if digest32?(plan) and digest32?(range) and
         plan == Map.get(r, :execution_plan_sha256) and
         range == Map.get(r, :target_range_sha256),
       do: :ok,
       else: {:error, :binding}
  end

  # MUST equal the CARRIER's immutable class -- a grant for one traffic class must not
  # authorize work in another.
  defp traffic_class(c, j) do
    tc = Map.get(j, :traffic_class)

    if tc in @traffic_classes and tc == Map.get(c, :traffic_class),
      do: :ok,
      else: {:error, :binding}
  end

  defp collection_window(j, env_not_before, env_expires) do
    nb = Map.get(j, :collection_not_before_unix_nano)
    ex = Map.get(j, :collection_expires_unix_nano)

    cond do
      # A REAL grant. 0 is the proto default, so an unset bound must not pose as one.
      not (pos_int64?(nb) and int64?(ex)) or ex <= nb ->
        {:error, :binding}

      # CONTAINMENT, not merely "a window". Calling the inner grant tighter does not make it
      # so: an inner window reaching outside the envelope would permit instants the envelope
      # never covered, so a grant wider than the capability carrying it is REJECTED outright
      # rather than silently intersected.
      nb < env_not_before or ex > env_expires ->
        {:error, :binding}

      true ->
        :ok
    end
  end

  # BOTH members. An id alone names a carrier without pinning which REVISION was permitted,
  # which is what would let a grant float across recompilations.
  defp exact_carrier(c, j) do
    sha = Map.get(j, :compiled_assignment_sha256)

    if digest32?(sha) and
         Map.get(j, :compiled_assignment_id) == Map.get(c, :compiled_assignment_id) and
         sha == Map.get(c, :compiled_assignment_sha256),
       do: :ok,
       else: {:error, :binding}
  end

  # Present EXACTLY WHEN the record carries one, checked in BOTH directions so neither
  # absence can skip a comparison.
  defp source_identity(r, j) do
    id = Map.get(r, :source_identity)
    claimed = Map.get(j, :source_identity)

    cond do
      id == nil != (claimed == nil) ->
        {:error, :binding}

      id == nil ->
        :ok

      # BOTH sides must be the generated struct. A nested `source_identity: 7` passes the
      # claim-body type check (which only inspects the claim itself) and then raises on the
      # first member read. The type guard belongs where the members are read.
      not (is_struct(id, EdgeSourceSpanIdentityV1) and
               is_struct(claimed, EdgeSourceSpanIdentityV1)) ->
        {:error, :binding}

      Map.get(claimed, :kind) == Map.get(id, :kind) and
        Map.get(claimed, :context_id) == Map.get(id, :context_id) and
        Map.get(claimed, :source_scope_id) == Map.get(id, :source_scope_id) and
          Map.get(claimed, :source_scope_sha256) == Map.get(id, :source_scope_sha256) ->
        :ok

      true ->
        {:error, :binding}
    end
  end

  defp role(grant) do
    if CapabilitySigning.purpose(grant) == :assignment_execution,
      do: :ok,
      else: {:error, :purpose}
  end

  defp digest32?(v), do: is_binary(v) and byte_size(v) == @sha256_bytes
  defp int64?(v), do: is_integer(v) and v >= -0x8000000000000000 and v <= 0x7FFFFFFFFFFFFFFF
  defp pos_int64?(v), do: is_integer(v) and v > 0 and v <= 0x7FFFFFFFFFFFFFFF
  defp within?(now, nb, ex), do: is_integer(nb) and is_integer(ex) and now >= nb and now < ex
end
