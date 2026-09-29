defmodule ServiceRadar.Edge.RecoveryValidate do
  @moduledoc """
  RELATIONAL validation of a spool-loss manifest and its tombstone.

  This is NEW code, not a port of a pre-existing Elixir validator: before 1.6a the
  Elixir side had `HashGrammar` only, so it could recompute a digest but could not
  say whether a manifest was WELL-FORMED. Go's `edgerecord` performed every
  relational check alone, which made "both runtimes agree" true of the digest and
  vacuous of everything else.

  It mirrors `go/pkg/edge/edgerecord/recovery.go` decision-for-decision. Where the
  two could drift, the shared fixture corpus is what catches it -- these functions
  exist so there is something on this side for the corpus to exercise.

  ## What is deliberately NOT here

  Byte accounting for a decoded page. `manifest_chain/2` is handed structs and
  cannot see received bytes; `manifest_chain_from_raw/2` is the entry point that
  bounds them. Splitting them keeps the impossible check from looking possible.
  """

  import Bitwise, only: []

  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Edge.WireShape

  # Mirrors Go's edgerecord constants. A divergence here is a cross-language bug, so
  # the shared fixtures pin them rather than trusting these literals.
  @recovery_digest_version 1
  @max_manifest_pages 1024
  @max_spans_per_page 256

  # The tombstone reason bound, 1..@max_reason_bytes. Go applies it in `recoveryControlBody` on
  # the SIGNED path, which is the only place it is reachable, so it arrives with `control_body/1`
  # rather than with the assembly validators above.
  @max_reason_bytes 256

  # The reserved recovery lane's three coordinates. Named once so the rule reads as one fact.
  @recovery_family :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
  @recovery_route :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
  @recovery_source_kind :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL

  # The clock-tolerance cap, matching Go's MaxClockToleranceNano. A supplied tolerance outside
  # [0, cap] is a REFUSAL rather than a clamp: a caller asking for an eight-hour window has a
  # different idea of the boundary than this one does, and silently narrowing it hides that.
  @max_clock_tolerance_nano 5 * 60 * 1_000_000_000
  @max_manifest_bytes 256 * 1024
  @sha256_len 32
  @uuid_len 16

  # Frozen v1 ACCEPTED SETS -- not "any declared member". A member added by a later
  # proto revision must NOT begin hashing under an unchanged @recovery_digest_version;
  # admitting one is a deliberate grammar version change.
  #
  # DERIVED AT COMPILE TIME from the shared enum-policy map, NOT restated. That map is
  # the one the Go enum-policy manifest is compared against, so deriving here makes
  # this module provably policed by the same contract. Local copies looked identical
  # but were only checked by tests that iterated those same copies: removing a member
  # here would have shortened the positive test with it, left the manifest comparing Go
  # against SemanticValidate, and stayed green while Go accepted a value this admission
  # path rejected.
  @accepted_reasons Map.fetch!(
                      SemanticValidate.enum_field_policy(),
                      {EdgeUnattributableV1, :reason}
                    )

  @accepted_source_kinds Map.fetch!(
                           SemanticValidate.enum_field_policy(),
                           {EdgeSourceSpanIdentityV1, :kind}
                         )

  @typedoc """
  RELATIONAL failures -- the manifest itself is well-formed enough to inspect and is
  wrong. Every one of these is a permanent verdict about the data.
  """
  @type error ::
          :unknown_fields
          | :manifest_empty
          | :manifest_bounds
          | :manifest_digest_version
          | :manifest_recovery_id
          | :manifest_chain
          | :manifest_page_digest
          | :manifest_terminal
          | :manifest_span
          | :manifest_span_body
          | :manifest_root
          | :tombstone_mismatch

  @typedoc """
  DECODE outcomes propagated verbatim from `ServiceRadar.Edge.WireDecode`.

  These are NOT relational errors and callers MUST NOT treat them as one:
  `:not_ready` and `:systemic` are deployment/decoder faults that require PAUSE AND
  REPLAY, while `:poison` and `:too_large` authorize permanent resolution. They are a
  SEPARATE type precisely so a caller pattern-matching on `t:error/0` cannot silently
  absorb a transient fault as a permanent one.
  """
  @type decode_error :: :not_ready | :systemic | :poison | :too_large

  @typedoc "Anything `manifest_chain_from_raw/2` can return."
  @type raw_error :: error() | decode_error()

  @doc """
  The RAW-BYTE entry point: bounds every page on the bytes ACTUALLY RECEIVED,
  before any decode, then validates the decoded chain.

  BOUND FIRST, DECODE SECOND. Interleaving them would let a page that fails to
  decode mask a later page's budget violation, and would decode bytes the budget
  already rejects.

  A per-page check is not sufficient on its own: `@max_manifest_bytes` is an
  AGGREGATE budget, so two pages can each be under the cap in received bytes,
  exceed it together, and collapse back under it when re-encoded. Summing
  re-encoded sizes therefore admits an over-budget manifest whose pages carry
  duplicate fields or non-minimal varints.
  """
  @spec manifest_chain_from_raw([binary()], binary() | nil) :: :ok | {:error, raw_error()}
  def manifest_chain_from_raw([], _expected_root), do: {:error, :manifest_empty}

  def manifest_chain_from_raw(raw, _expected_root) when not is_list(raw),
    do: {:error, :manifest_bounds}

  def manifest_chain_from_raw(raw, expected_root) when is_list(raw) do
    with :ok <- bound_received(raw),
         {:ok, pages} <- decode_all(raw) do
      manifest_chain(pages, expected_root)
    end
  end

  # BOUNDED COUNT, not a `length/1` GUARD. A guard clause calling `length/1` walks the whole
  # supplied list before the ceiling can reject it -- the traversal the ceiling exists to
  # prevent. `within?/2` walks at most @max_manifest_pages + 1 cells and answers the same
  # question for every input.
  defp bound_received(raw) when not is_list(raw), do: {:error, :manifest_bounds}

  defp bound_received(raw) do
    if BoundedList.within?(raw, @max_manifest_pages),
      do: bound_received_bytes(raw),
      else: {:error, :manifest_bounds}
  end

  defp bound_received_bytes(raw) do
    total =
      Enum.reduce_while(raw, 0, fn b, acc ->
        # TOTAL over the supplied term. `byte_size/1` RAISES on a non-binary, and this
        # function's contract is `{:error, reason}`; a page that is not bytes has no size to
        # bound, which is a bounds refusal.
        size = if is_binary(b), do: byte_size(b), else: :not_bytes

        if size == :not_bytes or size > @max_manifest_bytes or acc + size > @max_manifest_bytes do
          {:halt, :over}
        else
          {:cont, acc + size}
        end
      end)

    if total == :over, do: {:error, :manifest_bounds}, else: :ok
  end

  # Decoding goes through the shared WireDecode stage, so a recovery page gets the
  # same recursive structural gate as every other ingress rather than a private
  # `Protobuf.decode` that skips it.
  # The decoder is HARD-WIRED. An injectable one would let a caller pass malformed raw
  # bytes together with `fn _ -> {:ok, valid_page} end` and be admitted, skipping
  # WireDecode and WireValidate entirely -- exactly the caller-defined-decoder bypass
  # the finite-stage boundary exists to forbid. Propagation is proven instead through
  # `propagate_decode_error/1`, which cannot authorize anything.
  defp decode_all(raw) do
    raw
    |> Enum.reduce_while({:ok, []}, fn b, {:ok, acc} ->
      case WireDecode.decode_manifest_page(b) do
        # Success is handled HERE and never travels through the helper: a helper that
        # accepts a caller-supplied {:ok, page} could hand back a page, which is the
        # capability this module must not expose at all.
        {:ok, page} -> {:cont, {:ok, [page | acc]}}
        {:error, _} = err -> {:halt, propagate_decode_error(err)}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc """
  Validates a DECODED manifest chain.

  Does NOT enforce the received-byte budget -- it is handed structs and cannot see
  the wire bytes. Callers holding them MUST use `manifest_chain_from_raw/2`.
  """
  @spec manifest_chain([struct()], binary() | nil) :: :ok | {:error, error()}
  def manifest_chain([], _expected_root), do: {:error, :manifest_empty}

  def manifest_chain(pages, _expected_root) when not is_list(pages),
    do: {:error, :manifest_bounds}

  def manifest_chain(pages, expected_root) when is_list(pages) do
    # STRUCTURAL COUNTS BEFORE THE RECURSIVE WALK. `no_unknown_fields?/1` descends into every
    # classification span of every page, so bounding the page list and each page's span count
    # afterwards did the work these ceilings exist to prevent. Both are bounded counts.
    #
    # PRECEDENCE, frozen and matching Go: an oversize page list whose pages ALSO carry
    # unknown fields is a :manifest_bounds refusal.
    with :ok <- check(BoundedList.within?(pages, @max_manifest_pages), :manifest_bounds),
         :ok <-
           check(
             Enum.all?(pages, &BoundedList.nonempty_within?(spans_of(&1), @max_spans_per_page)),
             :manifest_bounds
           ),
         # AFTER both ceilings, which read only through the total `spans_of/1`. Placing it
         # first would report a partial map carrying an over-ceiling span list as a chain
         # fault when it is a bounds fault.
         :ok <- page_shapes(pages),
         :ok <- check(Enum.all?(pages, &no_unknown_fields?/1), :unknown_fields),
         count = length(pages),
         recovery_id = hd(pages).recovery_id,
         :ok <- check(uuidv7?(recovery_id), :manifest_recovery_id),
         :ok <- walk_pages(pages, recovery_id, count) do
      check_root(pages, expected_root)
    end
  end

  defp walk_pages(pages, recovery_id, count) do
    pages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {page, i}, {:ok, prev_through} ->
      case page_ok(page, pages, recovery_id, count, i, prev_through) do
        {:ok, last} -> {:cont, {:ok, last}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, :manifest_span}
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp page_ok(page, pages, recovery_id, count, i, prev_through) do
    spans = page.classification_spans

    with :ok <- check(page.digest_version == @recovery_digest_version, :manifest_digest_version),
         :ok <- check(page.recovery_id == recovery_id, :manifest_recovery_id),
         :ok <- check(page.page_count == count and page.page_index == i, :manifest_chain),
         # The span count (at least one -- an empty page has no derivable extent -- and at
         # most @max_spans_per_page) is bounded ABOVE, before the recursive walk. Re-checking
         # it here would be dead code that reads like the enforcement point.
         # REJECT BEFORE HASHING. Every span body -- including the CLOSED enum sets --
         # is checked before this page is hashed, so the verdict for an unaccepted
         # value cannot depend on the supplied digest.
         :ok <- Enum.reduce_while(spans, :ok, &body_reducer/2),
         :ok <-
           check(
             HashGrammar.manifest_page_digest(page) == page.page_sha256,
             :manifest_page_digest
           ),
         :ok <- check(page.terminal == (i == count - 1), :manifest_terminal),
         :ok <- prev_link_ok(page, pages, i) do
      order_spans(spans, prev_through)
    end
  end

  defp body_reducer(span, :ok) do
    # DEEP here, where the reason is `:manifest_span_body`. This covers the oneof body and
    # everything under it -- identity, source -- so a term the wire could not carry is a body
    # fault rather than a raise inside the digest.
    case if(WireShape.wire_shaped?(span),
           do: span_body(span),
           else: {:error, :manifest_span_body}
         ) do
      :ok -> {:cont, :ok}
      err -> {:halt, err}
    end
  end

  defp prev_link_ok(page, _pages, 0),
    do: check(page.prev_page_sha256 in [nil, ""], :manifest_chain)

  defp prev_link_ok(page, pages, i),
    do: check(page.prev_page_sha256 == Enum.at(pages, i - 1).page_sha256, :manifest_chain)

  # Strictly ascending and non-overlapping across the WHOLE chain, not merely within a
  # page: a within-page rule lets two individually valid pages describe overlapping
  # loss and double-count the union.
  #
  # ADJACENCY IS PERMITTED, unlike the retired lost_ranges rule. Gaps are legal and
  # mean "not lost", so a producer may legitimately emit [1,1] and [2,2] separately
  # when their classification bodies differ.
  defp order_spans(spans, prev_through) do
    Enum.reduce_while(spans, {:ok, prev_through}, fn sp, {:ok, prev} ->
      cond do
        # Primitively valid on its own: a single span with a zero or inverted interval
        # violates no ordering rule, so ordering alone does not exclude it.
        sp.from_sequence == 0 -> {:halt, {:error, :manifest_span}}
        sp.through_sequence < sp.from_sequence -> {:halt, {:error, :manifest_span}}
        prev != nil and sp.from_sequence <= prev -> {:halt, {:error, :manifest_span}}
        true -> {:cont, {:ok, sp.through_sequence}}
      end
    end)
  end

  defp check_root(_pages, nil), do: :ok
  defp check_root(_pages, ""), do: :ok

  defp check_root(pages, expected_root),
    do: check(HashGrammar.manifest_root(pages) == expected_root, :manifest_root)

  # The oneof guarantees AT MOST ONE body; exactly-one is enforced here, because a
  # proto3 oneof can legitimately be unset. Likewise proto3 still permits a set body
  # with a nil identity, empty required bytes, or a wrong-width digest.
  # EACH ONEOF BODY IS MATCHED AS ITS GENERATED STRUCT. A span may be a real
  # `%EdgeClassificationSpanV1{}` while its oneof body is a bare map, and `b.identity` on a
  # map without that key raises KeyError inside a function contracted to return
  # `{:error, reason}`. Matching the struct makes an unrecognised body the same typed
  # refusal as an unset oneof, which is what it is: a classification no consumer can act on.
  defp span_body(%{classification: {:attributed_active, %EdgeAttributedActiveV1{} = b}}) do
    with :ok <- identity(b.identity) do
      # range_sha256 is REQUIRED on ACTIVE and absent on PASSIVE.
      check(digest32?(b.range_sha256), :manifest_span_body)
    end
  end

  defp span_body(%{classification: {:attributed_passive, %EdgeAttributedPassiveV1{} = b}}),
    do: identity(b.identity)

  defp span_body(%{classification: {:unattributable, %EdgeUnattributableV1{} = b}}),
    do: check(b.reason in @accepted_reasons, :manifest_span_body)

  # An unset oneof, or a body that is not the generated struct its tag names.
  defp span_body(_), do: {:error, :manifest_span_body}

  defp identity(%EdgeAttributedSpanIdentityV1{} = id) do
    # Canonical UUIDs, not merely non-empty: the accepted-record validators already
    # require canonical UUIDs for these, and a weaker manifest rule would admit
    # attributed identities no valid record could have produced.
    with :ok <-
           check(
             uuid?(id.producer_assignment_id) and uuid?(id.run_id) and
               uuid?(id.production_scope_id),
             :manifest_span_body
           ),
         :ok <-
           check(
             digest32?(id.scope_sha256) and digest32?(id.contract_bundle_sha256),
             :manifest_span_body
           ) do
      source(id.source)
    end
  end

  # Absent, or not the generated struct -- same reason as the bodies above.
  defp identity(_), do: {:error, :manifest_span_body}

  # An ABSENT source is legal HERE -- and is NOT the same as PASSIVE. Source presence and
  # attribution classification are INDEPENDENT axes; all four combinations are
  # representable at the record/classification layers. A PAYLOAD contract may still
  # require source authority (SweepObservationBatchV1 does); this validator is the
  # recovery lane and imposes no such requirement of its own.
  defp source(nil), do: :ok

  # All four members travel together; a partial combination is rejected.
  #
  # NO CATCH-ALL, DELIBERATELY. `nil` is handled above and every other non-struct value is
  # refused by `WireShape.wire_shaped?/1` before `span_body/1` runs, so a fallback here is a
  # clause no input reaches. Shape is WireShape's job at this depth; this clause owns
  # SEMANTICS only.
  defp source(%EdgeSourceSpanIdentityV1{} = src) do
    check(
      src.kind in @accepted_source_kinds and uuid?(src.context_id) and
        uuid?(src.source_scope_id) and digest32?(src.source_scope_sha256),
      :manifest_span_body
    )
  end

  @doc """
  Validates a spool-loss tombstone against its manifest pages.

  Compares recovery id, digest version, page count, prior/new spool ids, and the
  ordered manifest root. It does NOT compare a loss interval or a coarsening flag:
  1.6a removes both from the tombstone. With gaps legal the manifest min/max is not
  the loss, and because the tombstone scope is signed that would have been an
  authenticated second source of truth.
  """
  @spec tombstone(struct(), [struct()]) :: :ok | {:error, error()}
  def tombstone(_t, pages) when not is_list(pages), do: {:error, :manifest_bounds}

  def tombstone(t, pages) when is_list(pages) do
    with :ok <- check(no_unknown_fields?(t), :unknown_fields),
         :ok <- check(uuidv7?(t.recovery_id), :tombstone_mismatch),
         :ok <-
           check(
             uuidv7?(t.prior_spool_id) and uuidv7?(t.new_spool_id),
             :tombstone_mismatch
           ),
         :ok <- check(t.prior_spool_id != t.new_spool_id, :tombstone_mismatch),
         :ok <- check(t.digest_version == @recovery_digest_version, :manifest_digest_version),
         # BOUNDED, and the two outcomes are DIFFERENT FAULTS. This runs before
         # manifest_chain/2's own ceiling, so `length/1` here walked the whole supplied list
         # ahead of the boundary meant to bound it -- and folding :over into the equality
         # reported an over-ceiling manifest as a CHAIN mismatch, which Go and the frozen
         # requirement both call a bounds fault.
         :ok <- tombstone_page_count(t, pages),
         :ok <- manifest_chain(pages, t.manifest_root_sha256) do
      check(t.recovery_id == hd(pages).recovery_id, :tombstone_mismatch)
    end
  end

  @typedoc """
  The SUPPLIED authorization policy, mirroring Go's `AuthorizationPolicy`.

  TRUST IS AN INPUT, NOT SOMETHING THIS MODULE OWNS. Go's boundary takes a `CapabilityTrust`
  INTERFACE and implements no key store either -- only the resolver knows which roles a key may
  issue, and which keys were revoked for COMPROMISE as opposed to rotated normally. So this peer
  is a faithful mirror of Go's shape rather than a reduced one: `:trust` is a function the caller
  supplies, and every key in one decision resolves at the single pinned `:trust_policy_epoch`, so
  a mid-decision revocation cannot mix snapshots.
  """
  @type key_status :: :valid | :historically_revoked | :invalid | :unavailable

  @type policy :: %{
          required(:trust) => (binary(), binary(), atom() ->
                                 {:ok, binary(), key_status()} | :error),
          required(:now_unix_nano) => integer(),
          required(:trust_policy_epoch) => non_neg_integer(),
          optional(:clock_tolerance_nano) => integer(),
          optional(:active_fence) => {:resolved, non_neg_integer()} | :unresolved
        }

  @doc """
  The SIGNED recovery-control boundary. Go's peer is `ValidateRecoveryControl`.

  ## Why the order is the contract

  The scope comparison is reachable ONLY after the signature verifies, and that ordering is half
  of what these rows freeze. A bare digest recomputation would be a different boundary wearing
  the same name: it would prove the transcript and prove nothing about who authorized the
  recovery operation, so a stale signature could masquerade as ceiling evidence.

  So this composes, in Go's order: signature and trust under the supplied policy, then contract
  dispatch, then the recovery lane and source kind, then the body, and only then the comparison
  of the recomputed scope digest against the SIGNED claim. The signed source scope must fix the
  exact recovery operation -- its `scope_id` is the recovery id and its `scope_sha256` is the
  canonical digest over the body -- so reusing a signature for a different spool pair or manifest
  root fails here rather than at assembly.
  """
  @spec recovery_control(term(), term(), policy()) :: :ok | {:error, atom()}
  def recovery_control(record, expected_contract, policy) do
    with :ok <- record_signed(record, policy),
         :ok <- contract_dispatch(record, expected_contract),
         :ok <- recovery_lane(record),
         {:ok, payload} <- inner_control_payload(record),
         {:ok, {rid, scope}} <- control_body(payload) do
      signed_scope_fixes_operation(record, rid, scope)
    end
  end

  @doc """
  The AUTHORIZATION half on its own: Go's `ValidateRecordSigned`.

  Structural validation first, then cryptographic verification of every present capability
  against the key the policy resolves, then the current-authority decision. A COMPROMISE-revoked
  key -- production OR source -- can never authorize here: the WORST status across both
  dominates, so a compromised source key downgrades the whole record even when production
  verifies.
  """
  @spec record_signed(term(), policy()) :: :ok | {:error, atom()}
  def record_signed(record, policy) do
    tolerance = Map.get(policy, :clock_tolerance_nano, 0)

    with :ok <- check(is_function(Map.get(policy, :trust), 3), :trust_missing),
         :ok <- check(Map.get(policy, :trust_policy_epoch, 0) != 0, :trust_epoch_unset),
         :ok <-
           check(
             is_integer(tolerance) and tolerance >= 0 and tolerance <= @max_clock_tolerance_nano,
             :clock_tolerance
           ),
         :ok <- SemanticValidate.validate_record(record),
         {:ok, production_status} <-
           verify_capability(record.production_capability, :production, policy),
         {:ok, worst} <- verify_source_authority(record, policy, production_status),
         :ok <- check(worst != :historically_revoked, :key_historically_revoked),
         :ok <- production_current(record.production_capability, policy, tolerance) do
      fence_relation(record, policy)
    end
  end

  @doc """
  Every invariant knowable from ONE recovery-control body before durable admission, returning
  the body's recovery id and its canonical recovery-operation SCOPE digest.

  Go's peer is `recoveryControlBody`. It is a DIFFERENT SITE from `tombstone/2` and
  `manifest_chain/2` above, and not a narrower version of them: those reconcile a declaration
  against SUPPLIED pages, while this one receives no page list at all. The tombstone's
  `manifest_page_count` here is therefore a DECLARED SCALAR committed by the scope digest exactly
  as signed -- an unbounded count would travel signed and be questioned, if ever, only at
  assembly. That is why the bound is `1..@max_manifest_pages` rather than merely non-zero.

  It returns the scope digest rather than comparing it, because the value it must equal lives in
  the signed source claims and only the composed boundary holds both.
  """
  @spec control_body(term()) :: {:ok, {binary(), binary()}} | {:error, error()}
  def control_body(payload)

  def control_body(%EdgeRecoveryControlPayloadV1{body: {:tombstone, t}}) do
    with :ok <- check(no_unknown_fields?(t), :unknown_fields),
         :ok <- check(uuidv7?(t.recovery_id), :tombstone_mismatch),
         :ok <-
           check(
             uuidv7?(t.prior_spool_id) and uuidv7?(t.new_spool_id) and
               t.prior_spool_id != t.new_spool_id,
             :tombstone_mismatch
           ),
         :ok <-
           check(
             t.digest_version == @recovery_digest_version and sha256?(t.manifest_root_sha256),
             :tombstone_mismatch
           ),
         :ok <-
           check(
             is_integer(t.manifest_page_count) and t.manifest_page_count >= 1 and
               t.manifest_page_count <= @max_manifest_pages,
             :tombstone_mismatch
           ),
         :ok <-
           check(
             is_integer(t.detected_at_unix_nano) and t.detected_at_unix_nano > 0,
             :tombstone_mismatch
           ),
         :ok <-
           check(
             is_binary(t.reason) and byte_size(t.reason) >= 1 and
               byte_size(t.reason) <= @max_reason_bytes,
             :tombstone_mismatch
           ) do
      {:ok, {t.recovery_id, HashGrammar.tombstone_scope_digest(t)}}
    end
  end

  def control_body(%EdgeRecoveryControlPayloadV1{body: {:manifest_page, p}}) do
    with :ok <- single_page(p) do
      {:ok, {p.recovery_id, HashGrammar.manifest_page_scope_digest(p)}}
    end
  end

  def control_body(%EdgeRecoveryControlPayloadV1{body: {:resolved, r}}) do
    with :ok <- check(no_unknown_fields?(r), :unknown_fields),
         :ok <-
           check(
             uuidv7?(r.recovery_id) and sha256?(r.manifest_root_sha256) and
               is_integer(r.applied_through_sequence) and r.applied_through_sequence > 0,
             :tombstone_mismatch
           ) do
      {:ok, {r.recovery_id, HashGrammar.resolved_scope_digest(r)}}
    end
  end

  # An absent body is a refusal, not an empty success: the oneof is the whole message.
  def control_body(_), do: {:error, :tombstone_mismatch}

  @doc """
  Every invariant knowable from ONE manifest page IN ISOLATION.

  Go's peer is `validateSingleManifestPage`. This is a DIFFERENT SITE from `page_ok/6`, which
  the chain walk uses: that one is handed its position by the walk and checks the page AGAINST
  the chain, while this one has only the page and reads `page_index` / `page_count` off the page
  itself. The span bound in particular is reachable here on the signed control path, where no
  chain exists yet.
  """
  @spec single_page(term()) :: :ok | {:error, error()}
  def single_page(%EdgeLossManifestPageV1{} = p) do
    spans = p.classification_spans

    with :ok <- check(no_unknown_fields?(p), :unknown_fields),
         :ok <- check(uuidv7?(p.recovery_id), :manifest_recovery_id),
         :ok <- check(p.digest_version == @recovery_digest_version, :manifest_digest_version),
         :ok <-
           check(
             p.page_count != 0 and p.page_index < p.page_count,
             :manifest_chain
           ),
         :ok <- check(p.terminal == (p.page_index == p.page_count - 1), :manifest_terminal),
         :ok <-
           check(
             byte_size(p.prev_page_sha256) == if(p.page_index == 0, do: 0, else: 32),
             :manifest_chain
           ),
         # BOTH ARMS. An empty page has no derivable extent, and the ceiling is the frozen
         # @max_spans_per_page -- Go's gate is one condition covering both, so a peer that
         # enforced only the ceiling would satisfy the over-bound row and pass the empty one.
         #
         # BoundedList, not length/1: a count ceiling exists to stop unbounded work, and
         # `length(spans) <= cap` performs exactly the traversal the ceiling forbids. The two
         # return the same verdict and differ only in cost, so no verdict vector detects it.
         :ok <-
           check(
             spans != [] and BoundedList.within?(spans, @max_spans_per_page),
             :manifest_bounds
           ),
         :ok <- ordered_spans(spans),
         # REJECT BEFORE HASHING, the same order page_ok/6 uses: every span body is checked
         # before the page is hashed, so the verdict for an unaccepted value cannot depend on
         # the supplied digest.
         :ok <- Enum.reduce_while(spans, :ok, &body_reducer/2) do
      check(HashGrammar.manifest_page_digest(p) == p.page_sha256, :manifest_page_digest)
    end
  end

  def single_page(_), do: {:error, :manifest_bounds}

  # from >= 1, through >= from, and strictly increasing with no overlap. ADJACENCY is permitted:
  # gaps are legal, and two adjacent spans may legitimately differ in classification body.
  defp ordered_spans(spans) do
    spans
    |> Enum.reduce_while({:ok, 0}, fn sp, {:ok, prev_through} ->
      cond do
        sp.from_sequence == 0 or sp.through_sequence < sp.from_sequence ->
          {:halt, {:error, :manifest_span}}

        prev_through != 0 and sp.from_sequence <= prev_through ->
          {:halt, {:error, :manifest_span}}

        true ->
          {:cont, {:ok, sp.through_sequence}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, err} -> {:error, err}
    end
  end

  defp sha256?(b), do: is_binary(b) and byte_size(b) == 32

  # --- the signed boundary's parts ---------------------------------------------------------

  # Resolve the issuer key at the PINNED epoch, then verify. A resolver that cannot answer is
  # :key_unavailable, not a pass: an unresolvable lookup fails closed exactly as a bad signature
  # does.
  defp verify_capability(nil, _purpose, _policy), do: {:error, :capability_missing}

  defp verify_capability(cap, purpose, policy) do
    case policy.trust.(cap.issuer_id, cap.issuer_key_id, purpose) do
      {:ok, public_key, status} ->
        cond do
          status == :invalid ->
            {:error, :key_invalid}

          status == :unavailable ->
            {:error, :key_unavailable}

          not CapabilitySigning.verify(cap, purpose, public_key) ->
            {:error, :signature}

          true ->
            {:ok, status}
        end

      _ ->
        {:error, :key_unavailable}
    end
  end

  # The source status is NOT discarded when it verifies: the WORST outcome across production and
  # source is what the decision uses, so a compromised source key cannot slip through behind a
  # production capability that happens to be clean.
  defp verify_source_authority(record, policy, production_status) do
    case record.source_authorization do
      nil ->
        {:ok, production_status}

      sa ->
        case verify_capability(sa.capability, :source, policy) do
          {:ok, source_status} -> {:ok, worst_status(production_status, source_status)}
          {:error, err} -> {:error, err}
        end
    end
  end

  defp worst_status(:historically_revoked, _), do: :historically_revoked
  defp worst_status(_, :historically_revoked), do: :historically_revoked
  defp worst_status(a, _), do: a

  # A FRESH apply requires production authority CURRENT at the trusted now, inclusive at both
  # ends, widened by the tolerance with saturating endpoints.
  defp production_current(cap, policy, tolerance) do
    now = policy.now_unix_nano

    check(
      now >= cap.not_before_unix_nano - tolerance and now <= cap.expires_at_unix_nano + tolerance,
      :authority_expired
    )
  end

  # Fence classification is EXPLICIT and the three outcomes are different faults. An unresolved
  # fence or a FUTURE epoch is retryable and never authorizes; a STALE epoch is fenced out.
  defp fence_relation(record, policy) do
    epoch = record.producer_context && record.producer_context.authority_epoch

    case Map.get(policy, :active_fence, :unresolved) do
      {:resolved, active} when is_integer(epoch) ->
        cond do
          epoch > active -> {:error, :fence_not_ready}
          epoch < active -> {:error, :fence_stale}
          true -> :ok
        end

      _ ->
        {:error, :fence_not_ready}
    end
  end

  defp contract_dispatch(_record, nil), do: {:error, :contract_dispatch}

  defp contract_dispatch(record, expected) do
    c = record.output_contract

    check(
      c != nil and c.contract_id == expected.contract_id and
        c.contract_version == expected.contract_version and
        c.contract_bundle_sha256 == expected.contract_bundle_sha256 and
        c.registry_epoch == expected.registry_epoch,
      :contract_dispatch
    )
  end

  # THE RESERVED RECOVERY LANE, and the framing family bound to this typed ingress (task 1.5-m).
  #
  # Go states this in two places: `validateRecoveryLane` inside the STRUCTURAL validator that
  # runs for every record, and the family check inside `ValidateRecoveryControl`. This runtime
  # cannot follow that split -- its generic validator is deliberately permissive, and that
  # permissiveness is a recorded manifest column, so making it strict would be a different
  # change wearing this one's name. The rule therefore lives HERE, at the typed boundary the
  # requirement binds it to, and BEFORE the payload is read as a contract message.
  #
  # All three arms carry ONE fault. They are not independent facts: a recovery payload on an
  # ordinary route, an ordinary payload on the recovery route, and a recovery payload without
  # recovery authority are the same violation of the reserved lane seen from three sides.
  defp recovery_lane(record) do
    with :ok <- check(record.payload_family == @recovery_family, :recovery_lane),
         :ok <- check(record.route_profile == @recovery_route, :recovery_lane) do
      sa = record.source_authorization
      check(sa != nil and sa.kind == @recovery_source_kind, :recovery_lane)
    end
  end

  defp inner_control_payload(record) do
    with {:ok, bytes} <- inner_bytes(record) do
      try do
        {:ok, EdgeRecoveryControlPayloadV1.decode(bytes)}
      rescue
        _ -> {:error, :payload_decode}
      end
    end
  end

  # Go's `innerPayload`: the carried bytes for an uncompressed record, the validated
  # decompression for a zstd one, and a REFUSAL for anything else. An unlisted compression value
  # is not "assume none".
  defp inner_bytes(%{compression: :EDGE_RECORD_COMPRESSION_NONE} = r), do: {:ok, r.payload}

  defp inner_bytes(%{compression: :EDGE_RECORD_COMPRESSION_ZSTD} = r) do
    case Compression.decompress(r.payload, r.uncompressed_size) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :compression}
    end
  end

  defp inner_bytes(_), do: {:error, :compression}

  # The record's signed recovery context and the body's recovery id must be the SAME operation,
  # and the signed scope must fix it: a record authorized for context A cannot ship a body for
  # context B, and the body cannot be an unrelated object left beside a stale payload.
  defp signed_scope_fixes_operation(record, rid, scope) do
    sa = record.source_authorization
    claims = sa.capability && source_claims(sa.capability)

    with :ok <- check(sa.context_id == rid, :tombstone_mismatch),
         :ok <- check(claims != nil and claims.scope_id == rid, :tombstone_mismatch) do
      check(claims.scope_sha256 == scope, :tombstone_mismatch)
    end
  end

  defp source_claims(%{claims: {:source, claims}}), do: claims
  defp source_claims(_), do: nil

  @doc """
  The frozen meaning of `RecoveryResolvedV1.applied_through_sequence`: the consumer's
  DURABLY APPLIED CONTIGUOUS PREFIX over the ALLOCATED sequence space.

  The highest S such that every allocated sequence at or below S is either durably
  applied by the consumer transaction, or ABSENT from a VALIDATED COMPLETE span
  union. The union is the LOST set, so only ABSENCE from a complete union establishes
  not-lost -- the inverse reading releases a journal over sequences never processed.

  It is NOT the maximum span end and NOT the allocated high-water. For lost spans
  `[1,1]` and `[100,100]` over an allocated space of 1..100 with only sequence 1
  applied, all three differ: max span end and high-water are 100, the correct value
  is 99. This gates durable journal release, so the wrong candidate discards data the
  consumer still owes.
  """
  @spec applied_through_sequence(non_neg_integer(), non_neg_integer(), MapSet.t(), [
          {non_neg_integer(), non_neg_integer()}
        ]) :: non_neg_integer()
  def applied_through_sequence(prior, allocated_high_water, _applied, _lost)
      when prior >= allocated_high_water, do: prior

  def applied_through_sequence(prior, allocated_high_water, applied, lost) do
    walk_spans(prior, allocated_high_water, applied, Enum.sort_by(lost, &elem(&1, 0)))
  end

  # TOTAL AND BOUNDED. An earlier version stepped one sequence at a time from prior+1
  # to the high-water, which was neither: gaps are LEGAL and arbitrarily wide, so a
  # trillion-wide gap cost a trillion iterations -- a liveness bug on valid input, not
  # a performance nit. This walks the ordered spans and clears each gap in ONE step;
  # inside a lost span the prefix advances only while consecutive sequences are
  # applied, so that region is bounded by the applied set rather than the span width.
  #
  # Complexity is O(n log n + |applied|) for n spans: this sorts defensively, because a
  # caller passing an unordered union would otherwise get a plausible wrong answer.
  # (Go takes the union already ordered and is O(n + |applied|).)
  defp walk_spans(s, high, _applied, []), do: max(s, high)

  defp walk_spans(s, high, applied, [{from, through} | rest]) do
    cond do
      through <= s ->
        walk_spans(s, high, applied, rest)

      from > s + 1 ->
        # Everything below this span's start is absent from the union, hence NOT LOST.
        cleared = min(from - 1, high)

        if cleared >= high,
          do: cleared,
          else: walk_spans(cleared, high, applied, [{from, through} | rest])

      true ->
        case advance_in_span(s, high, applied, max(s + 1, from), through) do
          {:blocked, s2} -> s2
          {:cleared, s2} -> walk_spans(s2, high, applied, rest)
        end
    end
  end

  defp advance_in_span(s, high, _applied, seq, through) when seq > through or seq > high,
    do: {:cleared, s}

  defp advance_in_span(s, high, applied, seq, through) do
    if MapSet.member?(applied, seq) do
      advance_in_span(seq, high, applied, seq + 1, through)
    else
      {:blocked, s}
    end
  end

  @doc false
  # ERROR-ONLY propagation. It takes an error and returns an error: it cannot decode,
  # cannot construct a page, and has no success clause to pass one through -- so
  # exposing it grants no capability whatsoever. An earlier version also accepted
  # `{:ok, page}`, which meant a caller could hand it a page and get one back; that
  # contradicted its own "produces no page" claim and was broader than the proof needs.
  #
  # It exists because propagation cannot otherwise be proven: fixed malformed bytes
  # only ever yield `:poison`, so a mutation collapsing `:not_ready`/`:systemic` -- the
  # transient outcomes whose loss is destructive, since they mean PAUSE AND REPLAY
  # rather than quarantine -- would survive an end-to-end-only suite.
  @spec propagate_decode_error({:error, decode_error()}) :: {:error, decode_error()}
  def propagate_decode_error({:error, reason}), do: {:error, reason}

  # CANONICAL UUID, mirroring Go's ValidateCanonicalUUID exactly: 16 bytes, RFC
  # version 1..8 in the high nibble of byte 6, RFC variant 10xx in byte 8, and not
  # all-zero. A bare byte_size check accepts the nil UUID and every non-RFC blob --
  # Elixir would admit an identity Go rejects, which is the parity this validator
  # exists to hold.
  defp uuid?(<<_::binary-size(6), v, _, var, _::binary-size(7)>> = b)
       when byte_size(b) == @uuid_len do
    version = Bitwise.bsr(v, 4)

    # The all-zero guard is REDUNDANT given the version range -- the nil UUID has
    # version nibble 0, which already fails 1..8 -- and is kept only to mirror Go's
    # ValidateCanonicalUUID structurally, so the two read as the same rule.
    version >= 1 and version <= 8 and Bitwise.band(var, 0xC0) == 0x80 and
      b != <<0::128>>
  end

  defp uuid?(_), do: false

  # UUIDv7 specifically, mirroring Go's ValidateUUIDv7: version nibble exactly 7 and
  # the RFC variant. Recovery and spool IDs are v7 because their embedded timestamp is
  # load-bearing; span/source identities are only required to be canonical, since a
  # scheduler legitimately allocates v4.
  defp uuidv7?(<<_::binary-size(6), v, _, var, _::binary-size(7)>> = b)
       when byte_size(b) == @uuid_len do
    Bitwise.band(v, 0xF0) == 0x70 and Bitwise.band(var, 0xC0) == 0x80
  end

  defp uuidv7?(_), do: false

  defp digest32?(b) when is_binary(b), do: byte_size(b) == @sha256_len
  defp digest32?(_), do: false

  # Appendix A requires unknown fields to be REJECTED in every grammar-covered
  # position BEFORE hashing: the field-framed digests walk DECLARED fields only, so
  # retained unknown bytes are invisible to the digest while still riding along on the
  # wire -- a page with retained unknowns keeps the same digest and would otherwise
  # validate. That is load-bearing for content addressing.
  #
  # RECURSIVE, matching Go's hasUnknownFields: a struct nested at any depth can carry
  # them, and a top-level-only check would miss a span body or a source identity.
  #
  # The RAW path already rejects ordinary unknown tags at the WireDecode gate; this
  # closes the same hole for callers handing in already-decoded structs.
  # TOTAL span accessor. `manifest_chain/2` accepts decoded structs, but a hand-built map may
  # omit the field entirely; returning a non-list lets the bounded count report :improper
  # rather than raising inside a counting helper.
  defp spans_of(%{classification_spans: spans}), do: spans
  defp spans_of(_), do: :absent

  # :over and a count mismatch are DIFFERENT FAULTS. Comparing the declared count is only
  # meaningful once the list is known to be within the ceiling.
  defp tombstone_page_count(t, pages) do
    case BoundedList.count_at_most(pages, @max_manifest_pages) do
      :over -> {:error, :manifest_bounds}
      :improper -> {:error, :manifest_bounds}
      {:ok, n} -> check(t.manifest_page_count == n, :manifest_chain)
    end
  end

  # TOTALITY: the count ceilings run ahead of the structural walk, so `hd(pages)` and every
  # field read below it would otherwise see shapes nothing has validated, raising KeyError
  # inside a function contracted to return `{:error, reason}`.
  #
  # THE GENERATED STRUCT, not a map with the right keys. `match?(%{recovery_id: _}, ...)`
  # accepts any map carrying that key and leaves every OTHER field -- page_index, page_count,
  # prev_page_sha256, terminal, and each span's own fields -- free to be missing, so the
  # KeyError simply moves further down. A page that is not `%EdgeLossManifestPageV1{}` has no
  # complete field set to validate, and the same holds for each span it carries.
  defp page_shapes(pages) do
    if Enum.all?(pages, &page_struct?/1), do: :ok, else: {:error, :manifest_chain}
  end

  # THE STRUCT NAME IS NOT THE SHAPE. `%EdgeLossManifestPageV1{}` proves what the struct is
  # CALLED; every field is still `term()`, so `terminal: :bad` or a non-integer sequence
  # reaches the field-framed digest and raises FunctionClauseError on `u64/1` or `bytes/1`.
  # `WireShape.wire_shaped?/1` checks each field against its GENERATED declared type and
  # recurses through spans, bodies, identities and sources.
  defp page_struct?(%EdgeLossManifestPageV1{classification_spans: spans} = page)
       when is_list(spans) do
    # SHALLOW at this level. A recursive check here would report a malformed classification
    # body as a PAGE fault, collapsing it into `:manifest_chain`; the span level below reports
    # `:manifest_span_body`, which is what a body no consumer can interpret actually is.
    WireShape.scalars_wire_shaped?(page) and
      Enum.all?(spans, &span_wire_shaped?/1)
  end

  defp page_struct?(_), do: false

  defp span_wire_shaped?(%EdgeClassificationSpanV1{} = span),
    do: WireShape.scalars_wire_shaped?(span)

  defp span_wire_shaped?(_), do: false

  defp no_unknown_fields?(%{__unknown_fields__: unknown}) when unknown not in [nil, []], do: false

  defp no_unknown_fields?(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.all?(&no_unknown_fields?/1)
  end

  # PROPER-LIST TOTAL, WHICH IS NOT THE SAME AS REFUSING. `is_list([1 | :tail])` is TRUE and
  # `Enum.all?/2` then raises on the tail, inside a predicate whose callers treat `false` as a
  # refusal and have no clause for an exception. Walking the cells explicitly stops the crash;
  # the improper TAIL then falls to the catch-all below, which answers `true` -- this predicate
  # asks about unknown fields, and an improper tail carries none. The REFUSAL comes from the
  # count ceiling or the shape check, both of which run first.
  defp no_unknown_fields?([]), do: true
  defp no_unknown_fields?([h | t]), do: no_unknown_fields?(h) and no_unknown_fields?(t)
  defp no_unknown_fields?({_tag, value}), do: no_unknown_fields?(value)
  defp no_unknown_fields?(_), do: true

  defp check(true, _err), do: :ok
  defp check(false, err), do: {:error, err}

  @doc false
  # Exposed so tests can assert the frozen sets directly rather than by inference.
  def accepted_reasons, do: @accepted_reasons
  @doc false
  def accepted_source_kinds, do: @accepted_source_kinds

  @doc false
  def limits,
    do: %{
      digest_version: @recovery_digest_version,
      max_manifest_pages: @max_manifest_pages,
      max_spans_per_page: @max_spans_per_page,
      max_manifest_bytes: @max_manifest_bytes
    }

  # Silence the unused-alias warning: EdgeLossManifestPageV1 documents what this
  # module validates even though every function takes an already-decoded struct.
  @doc false
  def page_module, do: EdgeLossManifestPageV1
end
