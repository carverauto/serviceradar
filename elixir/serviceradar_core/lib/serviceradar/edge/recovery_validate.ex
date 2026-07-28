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

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias ServiceRadar.Edge.WireDecode

  # Mirrors Go's edgerecord constants. A divergence here is a cross-language bug, so
  # the shared fixtures pin them rather than trusting these literals.
  @recovery_digest_version 1
  @max_manifest_pages 1024
  @max_spans_per_page 256
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
                      {Serviceradar.Edge.V1.EdgeUnattributableV1, :reason}
                    )

  @accepted_source_kinds Map.fetch!(
                           SemanticValidate.enum_field_policy(),
                           {Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1, :kind}
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

  def manifest_chain_from_raw(raw, expected_root) when is_list(raw) do
    with :ok <- bound_received(raw),
         {:ok, pages} <- decode_all(raw) do
      manifest_chain(pages, expected_root)
    end
  end

  defp bound_received(raw) when length(raw) > @max_manifest_pages, do: {:error, :manifest_bounds}

  defp bound_received(raw) do
    total =
      Enum.reduce_while(raw, 0, fn b, acc ->
        size = byte_size(b)

        if size > @max_manifest_bytes or acc + size > @max_manifest_bytes do
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

  def manifest_chain(pages, expected_root) when is_list(pages) do
    count = length(pages)

    with :ok <- check(Enum.all?(pages, &no_unknown_fields?/1), :unknown_fields),
         :ok <- check(count <= @max_manifest_pages, :manifest_bounds),
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
         # At least one span: an empty page has no derivable extent, so it can be
         # neither validated nor chained.
         :ok <- check(spans != [] and length(spans) <= @max_spans_per_page, :manifest_bounds),
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
    case span_body(span) do
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
  defp span_body(%{classification: {:attributed_active, b}}) do
    with :ok <- identity(b.identity) do
      # range_sha256 is REQUIRED on ACTIVE and absent on PASSIVE.
      check(digest32?(b.range_sha256), :manifest_span_body)
    end
  end

  defp span_body(%{classification: {:attributed_passive, b}}), do: identity(b.identity)

  defp span_body(%{classification: {:unattributable, b}}),
    do: check(b.reason in @accepted_reasons, :manifest_span_body)

  # Unset oneof: an interval with no classification, which no consumer can act on.
  defp span_body(_), do: {:error, :manifest_span_body}

  defp identity(nil), do: {:error, :manifest_span_body}

  defp identity(id) do
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

  # An ABSENT source is legal -- and is NOT the same as PASSIVE. Source presence and
  # attribution classification are INDEPENDENT axes; all four combinations are legal.
  defp source(nil), do: :ok

  # All four members travel together; a partial combination is rejected.
  defp source(src) do
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
         :ok <- check(t.manifest_page_count == length(pages), :manifest_chain),
         :ok <- manifest_chain(pages, t.manifest_root_sha256) do
      check(t.recovery_id == hd(pages).recovery_id, :tombstone_mismatch)
    end
  end

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
  defp no_unknown_fields?(%{__unknown_fields__: unknown}) when unknown not in [nil, []], do: false

  defp no_unknown_fields?(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.all?(&no_unknown_fields?/1)
  end

  defp no_unknown_fields?(list) when is_list(list), do: Enum.all?(list, &no_unknown_fields?/1)
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
