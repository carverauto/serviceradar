defmodule ServiceRadar.Edge.HashGrammar do
  @moduledoc """
  Elixir peer of the plan/recovery AND compiled-assignment digest grammars in
  `go/pkg/edge/edgerecord` (plan.go, recovery.go). The framing MUST match the Go
  `digestWriter` exactly: big-endian u64, length-framed bytes/strings, and 1-byte
  presence markers. These functions let the cross-language golden test prove the
  plan, recovery and compiled-assignment hash ABIs are identical in both languages,
  not merely that
  each side decodes protobuf.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias Serviceradar.Edge.V1.MtrCompletionDisposition

  @recovery_digest_version 1
  @plan_digest_version 1

  # Per-object domain tags (mirror plan.go / recovery.go): each self-hash preimage
  # leads with its own frozen string tag so digests of different object types can
  # never collide by field-structure coincidence. Part of the frozen ABI (#4710
  # Appendix A).
  @plan_range_domain "serviceradar.edge.plan.range.v1"
  @plan_page_domain "serviceradar.edge.plan.page.v1"
  @plan_root_domain "serviceradar.edge.plan.root.v1"
  @plan_header_domain "serviceradar.edge.plan.header.v1"
  @manifest_page_domain "serviceradar.edge.recovery.manifest_page.v1"
  @manifest_root_domain "serviceradar.edge.recovery.manifest_root.v1"

  # --- recovery manifest ---

  @spec manifest_page_digest(map()) :: binary()
  def manifest_page_digest(p) do
    io = [
      str(@manifest_page_domain),
      u64(p.digest_version),
      bytes(p.recovery_id),
      u64(p.page_index),
      u64(p.page_count),
      bytes(p.prev_page_sha256),
      present(p.terminal),
      u64(length(p.classification_spans)),
      Enum.map(p.classification_spans, &classification_span/1)
    ]

    :crypto.hash(:sha256, io)
  end

  # Frozen oneof member field numbers. These ARE the transcript discriminant, so they
  # are written out rather than derived: a renumbered oneof would silently change
  # every page digest.
  @span_member_active 3
  @span_member_passive 4
  @span_member_unattributable 5

  # EdgeClassificationSpanV1 framed field-by-field per Appendix A -- NOT a whole-
  # message encode, so it stays byte-identical to the Go peer at any depth.
  #
  # A repeated entry carries NO per-entry presence marker (the element count above
  # already establishes how many follow) and the oneof body carries none (the u64
  # discriminant names which body is set). Every OTHER nested message keeps its marker.
  defp classification_span(sp) do
    [
      u64(sp.from_sequence || 0),
      u64(sp.through_sequence || 0),
      span_body(sp.classification)
    ]
  end

  defp span_body({:attributed_active, b}) do
    [u64(@span_member_active), span_identity(b.identity), bytes(b.range_sha256)]
  end

  defp span_body({:attributed_passive, b}) do
    [u64(@span_member_passive), span_identity(b.identity)]
  end

  defp span_body({:unattributable, b}) do
    [u64(@span_member_unattributable), u64(reason_value(b.reason))]
  end

  # An unset oneof is REJECTED by the validator, but the grammar must still be total:
  # returning [] here keeps a digest computable for an invalid page rather than
  # raising, so the validator -- not this function -- decides the verdict.
  defp span_body(nil), do: []

  # The identity marker is emitted even though an unset identity is REJECTED: omitting
  # a marker for a field that "cannot" be absent is how two runtimes end up disagreeing
  # about whether the byte is there. The SOURCE marker is load-bearing rather than
  # merely structural -- absence is part of the span identity, so source-present and
  # source-absent spans MUST produce different preimages.
  defp span_identity(nil), do: present(false)

  defp span_identity(id) do
    [
      present(true),
      bytes(id.producer_assignment_id),
      bytes(id.run_id),
      u64(id.run_shard || 0),
      u64(id.authority_epoch || 0),
      bytes(id.production_scope_id),
      bytes(id.scope_sha256),
      bytes(id.contract_bundle_sha256),
      source_identity(id.source)
    ]
  end

  defp source_identity(nil), do: present(false)

  defp source_identity(src) do
    [
      present(true),
      u64(kind_value(src.kind)),
      bytes(src.context_id),
      bytes(src.source_scope_id),
      bytes(src.source_scope_sha256)
    ]
  end

  # Enum -> wire integer, resolved through the OWNING module. Deliberately two
  # functions rather than one generic helper: a shared one would take the module as a
  # parameter, and passing the wrong module would hash a different enum's numbering
  # for the same atom without anything failing.
  #
  # An UNKNOWN value arrives as a plain integer (protobuf-elixir keeps the tag for an
  # open proto3 enum, and the negative-tag patch preserves negatives), so it passes
  # through unchanged. The validator rejects values outside the frozen accepted set
  # BEFORE this is reached; keeping the grammar total means an invalid page still has
  # a computable digest rather than raising here.
  defp reason_value(v) when is_integer(v), do: v
  defp reason_value(v), do: Serviceradar.Edge.V1.EdgeUnattributableReason.value(v)

  defp kind_value(v) when is_integer(v), do: v
  defp kind_value(v), do: Serviceradar.Edge.V1.EdgeSourceAuthorizationKind.value(v)

  @spec manifest_root([map()]) :: binary()
  def manifest_root(pages) do
    io = [
      str(@manifest_root_domain),
      u64(@recovery_digest_version),
      u64(length(pages)),
      Enum.map(pages, &bytes(&1.page_sha256))
    ]

    :crypto.hash(:sha256, io)
  end

  # --- scheduler plan ---

  @spec range_digest(map()) :: binary()
  def range_digest(r) do
    io = [
      str(@plan_range_domain),
      u64(@plan_digest_version),
      bytes(r.range_id),
      str(r.cidr),
      str(r.first_address),
      str(r.last_address),
      u64(r.target_count),
      bytes(r.check_set_sha256),
      bytes(r.availability_policy_id),
      u64(r.mtr_admission_budget),
      # The EXACT admitted MTR count is part of the range's CONTENT: an assignment
      # binds to `range_sha256`, so leaving the window width outside the digest would
      # let two ranges share an identity while admitting different ordinal counts.
      # Absent presence hashes as 0, matching Go's zero-value getter.
      u64(r.mtr_ordinal_count || 0)
    ]

    :crypto.hash(:sha256, io)
  end

  @compiled_assignment_body_domain "serviceradar.edge.assignment.compiled.body.v1"
  @compiled_assignment_artifact_domain "serviceradar.edge.assignment.compiled.artifact.v1"

  @doc """
  Digest of a `CompiledSweepAssignmentV1` BODY -- what the collection capability SIGNS.

  Covers every body field and EXCLUDES both digest fields and the capability: a signature
  cannot cover itself. Peer of Go's `CompiledAssignmentBodyDigest`.
  """
  @spec compiled_assignment_body_digest(map()) :: binary()
  def compiled_assignment_body_digest(c) do
    io = [
      str(@compiled_assignment_body_domain),
      cu32(c.digest_version || 0),
      bytes(c.compiled_assignment_id),
      bytes(c.producer_assignment_id),
      bytes(c.execution_id),
      bytes(c.execution_plan_id),
      bytes(c.execution_plan_sha256),
      bytes(c.target_range_id),
      bytes(c.target_range_sha256),
      bytes(c.network_scope_id),
      bytes(c.authenticated_agent_id),
      cu32(c.execution_shard || 0),
      cu64(c.assignment_epoch || 0),
      cu64(c.config_generation || 0),
      cenum(enum_value(Serviceradar.Edge.V1.SweepResultFormat, c.result_format)),
      bytes(c.check_set_sha256),
      cenum(enum_value(Serviceradar.Edge.V1.EdgeRecordTrafficClass, c.traffic_class)),
      ci64(c.not_before_unix_nano || 0),
      ci64(c.expires_at_unix_nano || 0)
    ]

    :crypto.hash(:sha256, io)
  end

  @doc """
  CONTENT ADDRESS of a `CompiledSweepAssignmentV1`: the body digest PLUS the attached
  capability, under a SEPARATE domain so neither digest can be presented as the other.

  A body digest is not a content address for an artifact that also carries an authority:
  two carriers with identical bodies and different capabilities share a body digest. Peer
  of Go's `CompiledAssignmentArtifactDigest`.
  """
  @spec compiled_assignment_artifact_digest(map()) :: binary()
  def compiled_assignment_artifact_digest(c) do
    cap = Map.get(c, :collection_capability)

    io =
      [
        str(@compiled_assignment_artifact_domain),
        cu32(c.digest_version || 0),
        bytes(compiled_assignment_body_digest(c)),
        # A 1-byte presence marker, so "no capability" cannot collide with a present one.
        present(cap != nil)
      ] ++
        if cap == nil do
          []
        else
          [
            bytes(CapabilitySigning.signing_bytes(cap)),
            bytes(cap.signature)
          ]
        end

    :crypto.hash(:sha256, io)
  end

  @spec plan_page_digest(map()) :: binary()
  def plan_page_digest(p) do
    io = [
      str(@plan_page_domain),
      u64(p.digest_version),
      bytes(p.execution_plan_id),
      u64(p.page_index),
      u64(p.page_count),
      bytes(p.prev_page_sha256),
      bytes(p.check_set_sha256),
      u64(length(p.ranges)),
      Enum.map(p.ranges, fn r ->
        [
          bytes(r.range_id),
          bytes(r.range_sha256),
          str(r.cidr),
          str(r.first_address),
          str(r.last_address),
          u64(r.target_count),
          bytes(r.check_set_sha256),
          bytes(r.availability_policy_id),
          u64(r.mtr_admission_budget),
          u64(r.mtr_ordinal_count || 0)
        ]
      end)
    ]

    :crypto.hash(:sha256, io)
  end

  @spec plan_root([map()]) :: binary()
  def plan_root(pages) do
    io = [
      str(@plan_root_domain),
      u64(@plan_digest_version),
      u64(length(pages)),
      Enum.map(pages, &bytes(&1.page_sha256))
    ]

    :crypto.hash(:sha256, io)
  end

  @spec plan_header_digest(map()) :: binary()
  def plan_header_digest(h) do
    io = [
      str(@plan_header_domain),
      u64(h.digest_version),
      bytes(h.execution_plan_id),
      u64(h.page_count),
      u64(h.total_target_count),
      bytes(h.plan_root_sha256),
      bytes(h.check_set_sha256),
      bytes(h.availability_policy_id),
      # tag 9 (assignment_epoch) RETIRED: an immutable plan must not commit a value
      # that reassignment advances without changing the plan.
      bytes(h.network_scope_id),
      bytes(h.mtr_ordinal_range_commitment)
    ]

    :crypto.hash(:sha256, io)
  end

  # --- recovery-operation SCOPE digests ---
  #
  # A signed recovery source grant's scope_sha256 MUST equal one of these, binding the
  # grant to the exact operation. Each leads with @recovery_scope_version and a u64
  # body-kind discriminant (0=tombstone, 1=manifest-page, 2=resolved) -- mirror of
  # TombstoneScopeDigest / ManifestPageScopeDigest / ResolvedScopeDigest in recovery.go.
  @recovery_scope_version 1

  @spec tombstone_scope_digest(map()) :: binary()
  def tombstone_scope_digest(t) do
    io = [
      u64(@recovery_scope_version),
      u64(0),
      bytes(t.recovery_id),
      bytes(t.prior_spool_id),
      bytes(t.new_spool_id),
      bytes(t.manifest_root_sha256),
      u64(t.manifest_page_count)
    ]

    :crypto.hash(:sha256, io)
  end

  @spec manifest_page_scope_digest(map()) :: binary()
  def manifest_page_scope_digest(p) do
    io = [u64(@recovery_scope_version), u64(1), bytes(p.recovery_id), bytes(p.page_sha256)]
    :crypto.hash(:sha256, io)
  end

  @spec resolved_scope_digest(map()) :: binary()
  def resolved_scope_digest(rv) do
    io = [
      u64(@recovery_scope_version),
      u64(2),
      bytes(rv.recovery_id),
      bytes(rv.manifest_root_sha256),
      u64(rv.applied_through_sequence)
    ]

    :crypto.hash(:sha256, io)
  end

  # --- MTR completion proof (version-2 additive multiset accumulator) ---

  @mtr_completion_version 2
  # Mirrors Go MaxMtrCompletionOrdinals (2^31).
  @max_mtr_ordinals 2_147_483_648

  # The raw order-independent completion root: an additive 256-bit multiset hash
  # over per-leaf digests, bound to the expected ordinal count and plan root. A
  # leaf is `{ordinal, disposition, trace_id, range_sha256}`, the disposition
  # being a `Serviceradar.Edge.V1.MtrCompletionDisposition` value.
  #
  # PRIVATE on purpose, and reached ONLY from `mtr_completion_verify/5` once every
  # leaf has been validated. Go exports no unvalidated hasher --
  # `edgerecord.MtrCompletionRoot` folds through the accumulator, whose `Add`
  # rejects a bad disposition BEFORE it is widened to u64 and hashed. A public raw
  # hasher here would be the one path by which an unrecognised number enters the
  # frozen preimage and yields a root no other implementation can reproduce.
  @spec mtr_completion_root(
          [{non_neg_integer(), integer(), binary() | nil, binary()}],
          non_neg_integer(),
          binary(),
          binary()
        ) :: binary()
  defp mtr_completion_root(leaves, expected, plan_root, commitment) do
    acc =
      Enum.reduce(leaves, <<0::256>>, fn leaf, acc ->
        add256(acc, mtr_leaf_hash(leaf))
      end)

    :crypto.hash(:sha256, [
      u64(@mtr_completion_version),
      u64(expected),
      bytes(plan_root),
      bytes(commitment),
      bytes(acc)
    ])
  end

  # MaxPlanMtrOrdinals peer (Go: edgerecord.MaxPlanMtrOrdinals). Bounds the TOTAL
  # admitted MTR ordinals across ONE plan so that recomputing a commitment is bounded
  # WORK. Distinct from @max_mtr_ordinals, which bounds what the ordinal space can
  # REPRESENT. A Go-only ceiling would mean a plan Go rejects and Elixir accepts.
  @max_plan_mtr_ordinals 1_048_576

  @doc """
  Plan-global ordinal WINDOWS: each range's contiguous window offset, as the PREFIX
  SUM of `mtr_ordinal_count` over the ranges preceding it in plan order (pages by
  index, ranges as committed).

  Peer of Go's `edgerecord.PlanMtrWindows`. Returns `:error` without hashing anything
  when a range omits its REQUIRED count, a count exceeds its admission-budget CEILING,
  a range id repeats, or the plan's total exceeds the work ceiling.
  """
  @spec plan_mtr_windows([map()]) ::
          {:ok, %{binary() => non_neg_integer()}, non_neg_integer()} | :error
  def plan_mtr_windows(pages) do
    pages
    |> Enum.flat_map(& &1.ranges)
    |> Enum.reduce_while({:ok, %{}, 0}, fn r, {:ok, windows, next} ->
      cond do
        # REQUIRED PRESENCE: an absent count is not zero, it is a plan that never
        # stated its window.
        is_nil(r.mtr_ordinal_count) -> {:halt, :error}
        r.mtr_ordinal_count > (r.mtr_admission_budget || 0) -> {:halt, :error}
        Map.has_key?(windows, r.range_id) -> {:halt, :error}
        next + r.mtr_ordinal_count > @max_plan_mtr_ordinals -> {:halt, :error}
        true -> {:cont, {:ok, Map.put(windows, r.range_id, next), next + r.mtr_ordinal_count}}
      end
    end)
  end

  @doc """
  The additive multiset commitment for ONE plan range's ordinal window: the members
  `(offset + i, range_sha256)` for i in 1..count.

  Peer of Go's `edgerecord.MtrWindowCommitment`. It is RECOMPUTED from committed plan
  data, never trusted as carried bytes -- the count and the range digest determine it
  exactly, so accepting whatever an assignment carried would leave the per-attempt MTR
  authority self-asserted.
  """
  @spec mtr_window_commitment(non_neg_integer(), non_neg_integer(), binary()) :: binary() | :error
  def mtr_window_commitment(offset, count, range_sha256)
      when is_integer(offset) and offset >= 0 and is_integer(count) and count >= 0 and
             count <= @max_plan_mtr_ordinals and
             offset <= @max_plan_mtr_ordinals - count and is_binary(range_sha256) and
             byte_size(range_sha256) == 32 do
    # `1..count//1` for the same reason the completion fold uses it: an unstepped
    # `1..0` is a DESCENDING range that iterates [1, 0].
    Enum.reduce(1..count//1, <<0::256>>, fn i, acc ->
      add256(acc, member_hash(offset + i, range_sha256))
    end)
  end

  # A window that ends past the plan work ceiling (or is otherwise out of bounds) is
  # REJECTED rather than folded. Go bounds the window END the same way, so a
  # `(offset = ceiling, count = 1)` window is refused by both runtimes.
  def mtr_window_commitment(_offset, _count, _range_sha256), do: :error

  @doc """
  The PLAN-WIDE commitment: the additive sum of every range's window commitment, in
  plan order (pages by index, ranges as committed).

  Peer of Go's `edgerecord.PlanMtrOrdinalRangeCommitment`. Because the multiset hash is
  additive, the plan-wide value is exactly the sum of the per-assignment window values
  -- which is what makes a SPLIT plan verifiable while each attempt keeps its
  completion-leaf ordinals local to `{1..ordinal_count}`.
  """
  @spec plan_mtr_ordinal_range_commitment([map()]) :: {:ok, binary()} | :error
  def plan_mtr_ordinal_range_commitment(pages) do
    # Bounds are checked for the WHOLE plan BEFORE a single hash: an over-budget plan
    # must cost a walk, not a fold. A bound failure is a TYPED rejection, not a raised
    # MatchError -- a caller cannot pattern-match on a crash, and Go returns an error
    # here, so raising would make the two runtimes disagree about what "rejected" is.
    case plan_mtr_windows(pages) do
      :error ->
        :error

      {:ok, _windows, _total} ->
        pages
        |> Enum.flat_map(& &1.ranges)
        |> Enum.reduce_while({<<0::256>>, 0}, fn r, {acc, offset} ->
          count = r.mtr_ordinal_count || 0

          case mtr_window_commitment(offset, count, r.range_sha256) do
            :error -> {:halt, :error}
            window -> {:cont, {add256(acc, window), offset + count}}
          end
        end)
        |> case do
          :error -> :error
          {acc, _offset} -> {:ok, acc}
        end
    end
  end

  @doc "The plan's authenticated (ordinal, range_sha256) commitment (additive multiset hash)."
  @spec mtr_ordinal_range_commitment([{non_neg_integer(), any(), any(), binary()}]) :: binary()
  def mtr_ordinal_range_commitment(assignments) do
    Enum.reduce(assignments, <<0::256>>, fn {ord, _, _, range}, acc ->
      add256(acc, member_hash(ord, range))
    end)
  end

  defp member_hash(ordinal, range) do
    :crypto.hash(:sha256, [
      u64(@mtr_completion_version),
      bytes("mtr-completion-member"),
      u64(ordinal),
      bytes(range)
    ])
  end

  @doc """
  Verify exact-set coverage (the MSet-Add-Hash authenticated set) and return the
  root, mirroring `MtrCompletionAccumulator.Root`. Fails when the leaf ordinals do
  not form exactly {1..expected} -- e.g. {2,2,2} for expected 3, which count+sum
  cannot detect.

  `expected == 0` is LEGAL and is the plan that admits NO MTR targets: it requires
  EXACTLY the canonical zero-leaf proof -- no leaves, all accumulators the 32-byte
  zero value, `commitment` the 32 ZERO bytes of the empty-set multiset hash (never
  empty bytes), and the ordinary root framing bound to `plan_root`. It is not a
  licence to omit the proof: a COMPLETED event always carries one, so missing
  evidence can never masquerade as empty work.
  """
  @spec mtr_completion_verify(
          [{non_neg_integer(), integer(), binary() | nil, binary()}],
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          binary()
        ) ::
          {:ok, binary()} | :error
  def mtr_completion_verify(leaves, plan_ordinal_offset, expected, plan_root, commitment) do
    # Count-first bounds (mirrors Go) BEFORE the O(expected) canonical pass, then
    # per-leaf validation, then exact-set coverage + ordinal->range membership.
    cond do
      not (is_integer(expected) and expected >= 0 and expected <= @max_mtr_ordinals) -> :error
      not (is_integer(plan_ordinal_offset) and plan_ordinal_offset >= 0) -> :error
      plan_ordinal_offset > @max_mtr_ordinals - expected -> :error
      not (is_binary(plan_root) and byte_size(plan_root) == 32) -> :error
      not (is_binary(commitment) and byte_size(commitment) == 32) -> :error
      length(leaves) != expected -> :error
      not Enum.all?(leaves, &valid_completion_leaf?(&1, expected)) -> :error
      true -> verify_coverage(leaves, plan_ordinal_offset, expected, plan_root, commitment)
    end
  end

  defp verify_coverage(leaves, plan_ordinal_offset, expected, plan_root, commitment) do
    ordinal_acc =
      Enum.reduce(leaves, <<0::256>>, fn {ord, _, _, _}, acc -> add256(acc, ordinal_hash(ord)) end)

    # `1..expected//1`, NOT `1..expected`. At expected == 0 an unstepped `1..0` is a
    # DESCENDING range that iterates [1, 0], so the canonical accumulator would fold
    # two ordinal hashes for a completion that has none -- it would not merely be
    # wrong, it would reject every valid zero-MTR proof while accepting nothing. The
    # explicit step makes the range empty exactly when there is nothing to cover.
    # Go's `for i := 1; i <= expected; i++` is naturally empty here; Elixir is not.
    canonical =
      Enum.reduce(1..expected//1, <<0::256>>, fn i, acc -> add256(acc, ordinal_hash(i)) end)

    # MEMBERSHIP is folded over PLAN-GLOBAL ordinals, because that is what the
    # assignment's commitment was built over. Leaf hashes and the coverage
    # accumulator stay LOCAL: the leaf grammar and the exact-set `{1..expected}` check
    # are frozen. Only this accumulator is compared against a plan-derived value, so
    # only this one shifts.
    member_acc =
      Enum.reduce(leaves, <<0::256>>, fn {ord, _, _, range}, acc ->
        add256(acc, member_hash(plan_ordinal_offset + ord, range))
      end)

    if ordinal_acc == canonical and member_acc == commitment do
      {:ok, mtr_completion_root(leaves, expected, plan_root, commitment)}
    else
      :error
    end
  end

  defp valid_completion_leaf?({ord, disp, trace, range}, expected) do
    is_integer(ord) and ord >= 1 and ord <= expected and
      is_binary(range) and byte_size(range) == 32 and valid_completion_disposition?(disp, trace)
  end

  defp valid_completion_leaf?(_, _), do: false

  # A CLOSED set, and a CONSUMER of the generated enum rather than a restatement
  # of it. The disposition number is hashed into the frozen leaf preimage, so
  # literals here and an `iota` block in Go are two hand-maintained copies of one
  # numbering: disagree by one and the two runtimes produce different completion
  # roots for the same completion, surfacing as an unexplained proof mismatch
  # instead of a compile error. Zero, negative, and unknown-positive values are
  # rejected here, BEFORE `mtr_leaf_hash/1` widens the value to u64 -- and a value
  # declared in a LATER proto revision stays rejected until the completion grammar
  # version itself changes, because the leaf grammar is frozen.
  @disposition_trace_allocated MtrCompletionDisposition.value(
                                 :MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED
                               )

  @dispositions_without_trace Enum.map(
                                [
                                  :MTR_COMPLETION_DISPOSITION_NOT_ADMITTED,
                                  :MTR_COMPLETION_DISPOSITION_PROBE_FAILED,
                                  :MTR_COMPLETION_DISPOSITION_QUARANTINED,
                                  :MTR_COMPLETION_DISPOSITION_SCHEDULER_LOST
                                ],
                                &MtrCompletionDisposition.value/1
                              )

  defp valid_completion_disposition?(@disposition_trace_allocated, trace), do: uuidv7?(trace)

  defp valid_completion_disposition?(disp, trace) when disp in @dispositions_without_trace,
    do: trace in [nil, <<>>]

  defp valid_completion_disposition?(_, _), do: false

  defp uuidv7?(<<_::48, ver::4, _::12, var::2, _::62>>) when ver == 7 and var == 2, do: true
  defp uuidv7?(_), do: false

  defp ordinal_hash(ordinal) do
    :crypto.hash(:sha256, [
      u64(@mtr_completion_version),
      bytes("mtr-completion-ordinal"),
      u64(ordinal)
    ])
  end

  defp mtr_leaf_hash({ordinal, disposition, trace_id, range_sha256}) do
    :crypto.hash(:sha256, [
      u64(@mtr_completion_version),
      u64(ordinal),
      u64(disposition),
      bytes(trace_id),
      bytes(range_sha256)
    ])
  end

  # 256-bit big-endian addition mod 2^256 (the bitstring field truncates to 256 bits).
  defp add256(<<a::256>>, <<b::256>>), do: <<a + b::256>>

  # --- framing (must match the Go digestWriter) ---

  # CHECKED framing primitives for the compiled-assignment grammars.
  #
  # The shared `u64/1` below is UNCHECKED: a fixed-width bitstring silently
  # TRUNCATES an out-of-range integer, so 0 and 2^64 frame identically and a signed value
  # wraps. That is a digest ALIAS -- two different messages, one digest -- and these two
  # grammars are the carrier's content address, so an alias here is a forgery primitive.
  # (The older grammars' unchecked helpers are left alone: they are other tasks' frozen
  # surfaces, and widening this fix into them without their vectors would be a change
  # nobody has proven. Their exposure is real and is recorded in the task list.)
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @i64_max 0x7FFF_FFFF_FFFF_FFFF

  @u32_max 0xFFFF_FFFF
  @i32_min -0x8000_0000
  @i32_max 0x7FFF_FFFF

  # Each helper guards the field's OWN protobuf domain, not merely the framing width. A
  # uint32 field checked against the u64 ceiling accepts 2^32 -- a value the wire cannot
  # carry -- and frames it happily, so the guard has to match the declared type or it is only
  # a width check wearing a domain check's name.
  defp cu64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp cu32(v) when is_integer(v) and v >= 0 and v <= @u32_max, do: <<v::big-64>>
  defp ci64(v) when is_integer(v) and v >= @i64_min and v <= @i64_max, do: <<v::big-signed-64>>

  # Proto enums are INT32 on the wire, so an enum call site's domain is int32 -- not u64.
  defp cenum(v) when is_integer(v) and v >= @i32_min and v <= @i32_max, do: <<v::big-64>>

  # Enum fields decode to ATOMS; the grammar hashes the wire NUMBER.
  defp enum_value(_mod, v) when is_integer(v), do: v
  defp enum_value(mod, v) when is_atom(v) and not is_nil(v), do: mod.value(v)
  defp enum_value(_mod, nil), do: 0

  defp u64(v) when is_integer(v), do: <<v::big-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
  defp str(s), do: bytes(s || "")
  defp present(true), do: <<1>>
  defp present(false), do: <<0>>
end
