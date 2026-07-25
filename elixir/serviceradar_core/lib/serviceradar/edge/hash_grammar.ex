defmodule ServiceRadar.Edge.HashGrammar do
  @moduledoc """
  Elixir peer of the plan/recovery digest grammars in
  `go/pkg/edge/edgerecord` (plan.go, recovery.go). The framing MUST match the Go
  `digestWriter` exactly: big-endian u64, length-framed bytes/strings, and 1-byte
  presence markers. These functions let the cross-language golden test prove the
  plan and recovery hash ABIs are identical in both languages, not merely that
  each side decodes protobuf.
  """

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
      present(p.coarsened),
      u64(length(p.lost_ranges)),
      Enum.map(p.lost_ranges, fn r -> [u64(r.from_sequence), u64(r.through_sequence)] end),
      u64(length(p.affected)),
      Enum.map(p.affected, &affected_scope/1)
    ]

    :crypto.hash(:sha256, io)
  end

  # EdgeAffectedScopeV1 framed field-by-field per #4710 Appendix A -- NOT a whole-
  # message encode, so it stays byte-identical to the Go peer at any depth.
  defp affected_scope(a) do
    [
      u64(a.from_sequence || 0),
      u64(a.through_sequence || 0),
      bytes(a.contract_bundle_sha256),
      bytes(a.producer_assignment_id),
      bytes(a.run_id),
      u64(a.run_shard || 0),
      u64(a.authority_epoch || 0),
      bytes(a.scope_sha256),
      bytes(a.range_sha256),
      present(a.coarsened)
    ]
  end

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
      u64(r.mtr_admission_budget)
    ]

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
          u64(r.mtr_admission_budget)
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
      u64(h.assignment_epoch),
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
      u64(t.lost_from_sequence),
      u64(t.lost_through_sequence),
      bytes(t.manifest_root_sha256),
      u64(t.manifest_page_count),
      present(t.coarsened)
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

  @doc """
  Recompute the order-independent MTR completion root. Mirrors
  `edgerecord.MtrCompletionRoot`: an additive 256-bit multiset hash over per-leaf
  digests, bound to the expected ordinal count and plan root. A leaf is
  `{ordinal, disposition, trace_id, range_sha256}` where disposition is the
  integer disposition (allocated=1, not_admitted=2, ...).
  """
  @spec mtr_completion_root(
          [{non_neg_integer(), non_neg_integer(), binary() | nil, binary()}],
          non_neg_integer(),
          binary(),
          binary()
        ) :: binary()
  def mtr_completion_root(leaves, expected, plan_root, commitment) do
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
  """
  @spec mtr_completion_verify(
          [{non_neg_integer(), non_neg_integer(), binary() | nil, binary()}],
          pos_integer(),
          binary(),
          binary()
        ) ::
          {:ok, binary()} | :error
  def mtr_completion_verify(leaves, expected, plan_root, commitment) do
    # Count-first bounds (mirrors Go) BEFORE the O(expected) canonical pass, then
    # per-leaf validation, then exact-set coverage + ordinal->range membership.
    cond do
      not (is_integer(expected) and expected >= 1 and expected <= @max_mtr_ordinals) -> :error
      not (is_binary(plan_root) and byte_size(plan_root) == 32) -> :error
      not (is_binary(commitment) and byte_size(commitment) == 32) -> :error
      length(leaves) != expected -> :error
      not Enum.all?(leaves, &valid_completion_leaf?(&1, expected)) -> :error
      true -> verify_coverage(leaves, expected, plan_root, commitment)
    end
  end

  defp verify_coverage(leaves, expected, plan_root, commitment) do
    ordinal_acc =
      Enum.reduce(leaves, <<0::256>>, fn {ord, _, _, _}, acc -> add256(acc, ordinal_hash(ord)) end)

    canonical =
      Enum.reduce(1..expected, <<0::256>>, fn i, acc -> add256(acc, ordinal_hash(i)) end)

    member_acc = mtr_ordinal_range_commitment(leaves)

    if ordinal_acc == canonical and member_acc == commitment do
      {:ok, mtr_completion_root(leaves, expected, plan_root, commitment)}
    else
      :error
    end
  end

  # disposition ints: allocated=1, not_admitted=2, probe_failed=3, quarantined=4,
  # scheduler_lost=5. A v7 trace id is present ONLY for allocated.
  defp valid_completion_leaf?({ord, disp, trace, range}, expected) do
    is_integer(ord) and ord >= 1 and ord <= expected and
      is_binary(range) and byte_size(range) == 32 and valid_completion_disposition?(disp, trace)
  end

  defp valid_completion_leaf?(_, _), do: false

  defp valid_completion_disposition?(1, trace), do: uuidv7?(trace)
  defp valid_completion_disposition?(disp, trace) when disp in 2..5, do: trace in [nil, <<>>]
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

  defp u64(v) when is_integer(v), do: <<v::big-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
  defp str(s), do: bytes(s || "")
  defp present(true), do: <<1>>
  defp present(false), do: <<0>>
end
