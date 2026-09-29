defmodule ServiceRadar.Edge.PlanValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.ValidatePlanHeader` / `ValidatePlanPages` /
  `validateTargetRange`.

  It exists because deriving assignment authority from an UNVALIDATED plan is not a
  weaker check, it is no check: whoever supplies the plan chooses the range digests,
  the windows, and therefore the expectation an assignment is compared against.

  NO CARRIER TOKEN. An earlier revision returned an "opaque" tuple and claimed the
  relation could not be called without it -- but `@opaque` is DIALYZER METADATA, not a
  runtime guarantee, so a caller could construct the tuple around a rejected plan and
  the relation accepted it. The only construction that actually holds is for the
  relation to run this validation ITSELF, which is what
  `AssignmentValidate.validate_against_plan/3` now does.
  """

  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.HashGrammar

  @sha256_len 32
  @uuid_len 16
  @max_policy_id_bytes 128
  @max_range_str_bytes 64
  @max_plan_page_bytes 128 * 1024
  @max_manifest_pages 1024
  @max_ranges_per_page 256
  @plan_digest_version 1

  @type reason ::
          :header_identity
          | :header_digest
          | :page_digest
          | :page_chain
          | :page_bounds
          | :plan_root
          | :plan_totals
          | :plan_range
          | :check_set
          | :digest_version
          | :unknown_fields
          | :mtr_commitment
          | :mtr_window

  @doc """
  Fail-close a plan header and its page chain, returning each range's plan-global
  ordinal window offset.
  """
  @spec validate(term(), term()) ::
          {:ok, %{binary() => non_neg_integer()}} | {:error, reason()}
  def validate(header, pages) when is_map(header) and is_list(pages) do
    # STRUCTURAL COUNTS BEFORE THE RECURSIVE WALK. `no_unknown/1` descends into every range of
    # every page, so bounding the page list and each page's range count afterwards did the work
    # these ceilings exist to prevent. Both are BOUNDED counts, not `length/1`.
    #
    # PRECEDENCE, frozen and matching Go and the recovery peer: an oversize page list whose
    # pages ALSO carry unknown fields is a :page_bounds refusal.
    with :ok <- no_unknown(header),
         :ok <- header_identity(header),
         :ok <- header_digest(header),
         # PURE CEILING PREFLIGHT, after the header is trusted and before any page is
         # descended into. Only the ceilings move here: the page_count EQUALITY is a header
         # RELATION and stays below, so a stale header digest is still reported as a digest
         # fault rather than masked by a count mismatch. Go validates its header first for
         # the same reason.
         :ok <- count_ceilings(pages),
         :ok <- Enum.reduce_while(pages, :ok, &halt_on_error(no_unknown(&1), &2)),
         :ok <- page_count_matches(header, pages),
         :ok <- pages_and_ranges(header, pages),
         :ok <- plan_root(header, pages),
         {:ok, windows, _total} <- compute_windows(pages),
         :ok <- mtr_commitment(header, pages) do
      {:ok, windows}
    end
  end

  def validate(_header, _pages), do: {:error, :header_identity}

  @doc "Find a committed range by id within already-validated pages."
  @spec find_range([map()], binary()) :: map() | nil
  def find_range(pages, range_id) do
    pages |> Enum.flat_map(&(Map.get(&1, :ranges) || [])) |> Enum.find(&(&1.range_id == range_id))
  end

  defp halt_on_error(:ok, acc), do: {:cont, acc}
  defp halt_on_error(err, _acc), do: {:halt, err}

  defp no_unknown(m) when is_map(m) do
    # Retained unknown fields are rejected BEFORE any declared field is trusted: the
    # field-framed digests walk declared fields only, so retained bytes are invisible
    # to the digest while still riding on the wire. That is load-bearing for immutable
    # CONTENT ADDRESSING.
    ranges = Map.get(m, :ranges)

    nested =
      is_list(ranges) and
        Enum.any?(ranges, fn r -> is_map(r) and Map.get(r, :__unknown_fields__, []) != [] end)

    if Map.get(m, :__unknown_fields__, []) == [] and not nested,
      do: :ok,
      else: {:error, :unknown_fields}
  end

  # A non-map page/header is a SHAPE failure, not an unknown-field one: naming it
  # :unknown_fields would misreport why it was refused.
  defp no_unknown(_), do: {:error, :page_bounds}

  defp header_identity(h) do
    policy = Map.get(h, :availability_policy_id)

    # PROTOBUF DOMAINS, checked BEFORE anything is hashed. `total_target_count:
    # :bad` (or nil) reached plan_header_digest/1 and raised FunctionClauseError,
    # which is neither total nor typed -- the digest helper is not a validator and
    # must never be handed an unvalidated term.
    if uuidv7?(Map.get(h, :execution_plan_id)) and
         Map.get(h, :digest_version) == @plan_digest_version and
         digest?(Map.get(h, :plan_root_sha256)) and
         digest?(Map.get(h, :check_set_sha256)) and
         canonical_uuid?(Map.get(h, :network_scope_id)) and
         bounded_bytes?(policy, 1, @max_policy_id_bytes) and
         uint32?(Map.get(h, :page_count)) and Map.get(h, :page_count) > 0 and
         uint64?(Map.get(h, :total_target_count)) and
         uint32?(Map.get(h, :digest_version)) and
         digest?(Map.get(h, :mtr_ordinal_range_commitment)) do
      :ok
    else
      {:error, :header_identity}
    end
  end

  defp header_digest(h) do
    if digest?(Map.get(h, :execution_plan_sha256)) and
         HashGrammar.plan_header_digest(h) == Map.get(h, :execution_plan_sha256),
       do: :ok,
       else: {:error, :header_digest}
  end

  # PURE: the page-list and per-page range ceilings, and nothing that reads the header.
  defp count_ceilings(pages) do
    # BOUNDED COUNT, walked at most @max_manifest_pages + 1 cells. `length/1` measured the whole
    # attacker-supplied list to decide it was too long -- the traversal the ceiling forbids.
    case BoundedList.count_at_most(pages, @max_manifest_pages) do
      # A header declaring pages while supplying none is the case that made every
      # downstream check vacuous: with no pages, nothing is walked and nothing fails.
      {:ok, 0} -> {:error, :page_bounds}
      :over -> {:error, :page_bounds}
      :improper -> {:error, :page_bounds}
      {:ok, _} -> range_counts(pages)
    end
  end

  # A HEADER RELATION, not a ceiling: it stays after header validation and after the walk,
  # exactly where it was before the ceilings moved.
  defp page_count_matches(h, pages) do
    if Map.get(h, :page_count) == length(pages), do: :ok, else: {:error, :page_chain}
  end

  # Per-page range count, bounded, BEFORE any page's ranges are descended into.
  #
  # TOTAL over the supplied term. Running ahead of the structural walk means this now sees
  # page shapes nothing has validated -- `[:bad]` reached `Map.get(:bad, :ranges)` and raised
  # BadMapError, in a function whose contract is `{:error, reason}`. A page that is not a map
  # has no range list to count, which is a :page_bounds refusal and not a crash.
  defp range_counts(pages) do
    Enum.reduce_while(pages, :ok, fn p, :ok ->
      if BoundedList.nonempty_within?(ranges_of(p), @max_ranges_per_page),
        do: {:cont, :ok},
        else: {:halt, {:error, :page_bounds}}
    end)
  end

  @doc false
  # THE field preflight for a range's address strings: length bounds, then the IPv6-zone
  # prohibition. It PARSES NOTHING.
  #
  # IT RETURNS THE EXISTING `:plan_range` AND NOTHING NEW. `@doc false` and a `__` name do not
  # make a function private -- a test can call it, and any tag it returns is observable, so
  # a distinct tag per fault would BE a refusal class however it was labelled. That is task
  # 1.5-l's to mint, not this subtask's. Separate INPUTS prove the two predicates
  # independently, which is what the corpus needs; a distinct tag adds nothing it could not
  # already show.
  #
  # It is reachable from the corpus because that is the ONLY way to pin the frozen ceiling in
  # this runtime: no canonical address reaches it, and a one-over refusal driven through
  # `validate/2` survives the bound drifting anywhere between the longest valid address and the
  # ceiling, because the address parser refuses those lengths regardless.
  #
  # LENGTH FIRST, so an over-length value is not scanned at all. Then the ZONE: a zone names an
  # interface on the machine that WROTE the string and has no meaning at the receiver.
  #
  # THE ZONE IS REFUSED, NEVER STRIPPED. These strings feed the range, page, plan-root, header
  # and assignment digest chain, so repairing one forks a plan's identity from the bytes its
  # author signed.
  #
  # THE CHECK IS EXPLICIT rather than a consequence of parsing.
  # `:inet.parse_strict_address/1` ACCEPTS a zoned address and silently DISCARDS the zone, so
  # without this rule the value is refused downstream as a non-canonical SPELLING -- a
  # different stage, and a reason that names neither the zone nor the peer's cause.
  @spec __check_range_strings__(term(), term(), term()) ::
          {:ok, {:checked, binary(), binary(), binary()}} | {:error, :plan_range}
  def __check_range_strings__(cidr, first, last) do
    vals = [cidr, first, last]

    cond do
      not Enum.all?(vals, &is_binary/1) -> {:error, :plan_range}
      Enum.any?(vals, &(byte_size(&1) > @max_range_str_bytes)) -> {:error, :plan_range}
      Enum.any?(vals, &zoned?/1) -> {:error, :plan_range}
      # A CHECKED VALUE, not the bare strings: `span_size/1` takes only this shape, so reaching
      # the parser means having gone through here. It is NOT opaque -- a tagged tuple anything
      # in this module can build -- so what catches a bypass is the traced stage test, not the
      # shape.
      true -> {:ok, {:checked, cidr, first, last}}
    end
  end

  defp zoned?(s) when is_binary(s), do: :binary.match(s, "%") != :nomatch
  defp zoned?(_), do: false

  defp ranges_of(%{ranges: ranges}), do: ranges
  defp ranges_of(_), do: :absent

  defp pages_and_ranges(h, pages) do
    plan_id = Map.get(h, :execution_plan_id)
    header_check_set = Map.get(h, :check_set_sha256)
    header_policy = Map.get(h, :availability_policy_id)
    n = length(pages)

    pages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0, MapSet.new()}, fn {p, i}, {:ok, total, seen} ->
      ranges = Map.get(p, :ranges)
      prev = if i == 0, do: <<>>, else: Enum.at(pages, i - 1).page_sha256

      cond do
        # A malformed page or range LIST is a typed rejection, not a raise: `ranges:
        # :bad` and `ranges: [7]` previously crashed a validator whose contract promises
        # {:error, reason}.
        not is_map(p) or not is_list(ranges) or not Enum.all?(ranges, &is_map/1) ->
          {:halt, {:error, :page_bounds}}

        # Integer DOMAINS before the page digest hashes them.
        not uint32?(Map.get(p, :digest_version)) or not uint32?(Map.get(p, :page_index)) or
            not uint32?(Map.get(p, :page_count)) ->
          {:halt, {:error, :page_bounds}}

        # NESTED RANGE integers, preflighted here because plan_page_digest/1 hashes
        # every range INLINE -- so `target_count: nil` raised in HashGrammar.u64/1
        # before validate_range/3 ever ran, and an absent mtr_ordinal_count was hashed
        # as 0 before its later rejection. A digest helper is not a validator and must
        # never receive an unvalidated term.
        not Enum.all?(ranges, &range_integers_ok?/1) ->
          {:halt, {:error, :plan_range}}

        Map.get(p, :digest_version) != @plan_digest_version ->
          {:halt, {:error, :digest_version}}

        Map.get(p, :execution_plan_id) != plan_id ->
          {:halt, {:error, :page_chain}}

        Map.get(p, :page_index) != i or Map.get(p, :page_count) != n ->
          {:halt, {:error, :page_chain}}

        (Map.get(p, :prev_page_sha256) || <<>>) != prev ->
          {:halt, {:error, :page_chain}}

        # The range count is bounded ABOVE, before the recursive walk. Re-checking it here
        # would be dead code that reads like the enforcement point.

        Map.get(p, :check_set_sha256) != header_check_set ->
          {:halt, {:error, :check_set}}

        byte_size(encode_page(p)) > @max_plan_page_bytes ->
          {:halt, {:error, :page_bounds}}

        HashGrammar.plan_page_digest(p) != Map.get(p, :page_sha256) ->
          {:halt, {:error, :page_digest}}

        true ->
          case validate_ranges(ranges, header_check_set, header_policy, total, seen) do
            {:ok, total, seen} -> {:cont, {:ok, total, seen}}
            err -> {:halt, err}
          end
      end
    end)
    |> case do
      {:ok, total, _seen} ->
        # Reconcile the declared total, and detect uint64 OVERFLOW explicitly. Elixir
        # integers are arbitrary-precision, so a sum that wraps in Go simply grows here
        # -- without this the two runtimes would disagree about a plan whose range
        # counts sum past 2^64, which Go rejects via bits.Add64's carry.
        cond do
          total > 0xFFFFFFFFFFFFFFFF -> {:error, :plan_totals}
          total != Map.get(h, :total_target_count) -> {:error, :plan_totals}
          true -> :ok
        end

      err ->
        err
    end
  end

  defp validate_ranges(ranges, check_set, policy, total, seen) do
    Enum.reduce_while(ranges, {:ok, total, seen}, fn r, {:ok, acc, ids} ->
      case validate_range(r, check_set, policy) do
        :ok ->
          id = Map.get(r, :range_id)

          if MapSet.member?(ids, id) do
            {:halt, {:error, :plan_range}}
          else
            {:cont, {:ok, acc + Map.get(r, :target_count), MapSet.put(ids, id)}}
          end

        err ->
          {:halt, err}
      end
    end)
  end

  # The three integers BOTH grammars hash. Required presence is part of the domain:
  # `mtr_ordinal_count` absent is not zero, and hashing it as zero before rejecting it
  # would mean the digest saw a value the contract forbids.
  defp range_integers_ok?(r) do
    uint64?(Map.get(r, :target_count)) and
      uint64?(Map.get(r, :mtr_admission_budget)) and
      uint64?(Map.get(r, :mtr_ordinal_count))
  end

  defp validate_range(r, page_check_set, header_policy) do
    cidr = Map.get(r, :cidr) || ""
    first = Map.get(r, :first_address) || ""
    last = Map.get(r, :last_address) || ""

    # THE ADDRESS-STRING PREFLIGHT RUNS ONCE, HERE, and its result is the ONLY route to the
    # parser below. It reports the existing `:plan_range` for every fault -- naming a zone
    # fault distinctly is refusal taxonomy, which task 1.5-l owns.
    case __check_range_strings__(cidr, first, last) do
      {:error, _} -> {:error, :plan_range}
      {:ok, checked} -> validate_checked_range(r, checked, page_check_set, header_policy)
    end
  end

  defp validate_checked_range(
         r,
         {:checked, cidr, first, last} = checked,
         page_check_set,
         header_policy
       ) do
    has_cidr = cidr != ""
    has_span = first != "" or last != ""

    cond do
      not canonical_uuid?(Map.get(r, :range_id)) ->
        {:error, :plan_range}

      # The range's OWN content digest must reproduce: a changed CIDR under a stale
      # range_sha256 was accepted once the outer digests were resealed.
      not digest?(Map.get(r, :range_sha256)) ->
        {:error, :plan_range}

      HashGrammar.range_digest(r) != Map.get(r, :range_sha256) ->
        {:error, :plan_range}

      has_cidr == has_span ->
        {:error, :plan_range}

      not uint64?(Map.get(r, :target_count)) ->
        {:error, :plan_range}

      not uint64?(Map.get(r, :mtr_admission_budget)) ->
        {:error, :plan_range}

      Map.get(r, :target_count) == 0 ->
        {:error, :plan_range}

      not digest?(Map.get(r, :check_set_sha256)) ->
        {:error, :plan_range}

      Map.get(r, :check_set_sha256) != page_check_set ->
        {:error, :check_set}

      # EQUALITY ONLY -- the length bound is CENTRALIZED at the header, which `validate/2`
      # reaches before any range. A second length arm here would be unreachable on its own AND
      # would mask a missing header bound, so the rule lives in exactly one place.
      Map.get(r, :availability_policy_id) != header_policy ->
        {:error, :plan_range}

      true ->
        span_matches(r, checked)
    end
  end

  # The range expands to EXACTLY its address span, so the covered work set is
  # deterministic. Mirrors Go's rangeSpanSize, including the CANONICAL-SPELLING rule:
  # one network must not have two content digests.
  defp span_matches(r, {:checked, _, _, _} = checked) do
    case span_size(checked) do
      {:ok, size} ->
        if Map.get(r, :target_count) == size, do: :ok, else: {:error, :plan_range}

      :error ->
        {:error, :plan_range}
    end
  end

  defp span_size({:checked, "", first, last}) do
    with {:ok, f} <- parse_addr(first),
         {:ok, l} <- parse_addr(last),
         # Family mismatch is not a span.
         true <- tuple_size(f) == tuple_size(l),
         # CANONICAL SPELLING: one address must not have two textual forms, or one
         # network gets two content digests. Mirrors Go's `first.String() != input`.
         true <- canonical_addr?(f, first) and canonical_addr?(l, last) do
      fi = addr_to_int(f)
      li = addr_to_int(l)

      cond do
        li < fi -> :error
        li - fi + 1 > 0xFFFFFFFFFFFFFFFF -> :error
        true -> {:ok, li - fi + 1}
      end
    else
      _ -> :error
    end
  end

  defp span_size({:checked, cidr, _first, _last}) do
    with [addr, bits] <- String.split(cidr, "/", parts: 2),
         {bits_int, ""} <- Integer.parse(bits),
         {:ok, a} <- parse_addr(addr),
         # The WHOLE cidr must round-trip, PREFIX SUFFIX INCLUDED. Canonicalizing only
         # the address let `10.20.0.0/024` and `10.20.0.0/+24` through, because
         # Integer.parse accepts both -- two spellings of one network, so two content
         # digests.
         true <- canonical_cidr?(a, bits_int, cidr) do
      bit_len = if tuple_size(a) == 4, do: 32, else: 128
      host_bits = bit_len - bits_int

      cond do
        bits_int < 0 or bits_int > bit_len ->
          :error

        # HOST BITS SET means a non-canonical prefix. INTEGER masking across every
        # allowed width: an earlier revision used float `:math.pow`, capped the mask at
        # 62 bits and skipped `host_bits == 63` entirely, so `2001:db8::1/65` was
        # accepted while Go rejected it.
        host_bits > 0 and Bitwise.band(addr_to_int(a), Bitwise.bsl(1, host_bits) - 1) != 0 ->
          :error

        # A span whose exact host count exceeds uint64 must be split; saturation is not
        # an exact count.
        host_bits >= 64 ->
          :error

        true ->
          {:ok, Bitwise.bsl(1, host_bits)}
      end
    else
      _ -> :error
    end
  end

  # Re-render the parsed address and compare: `2001:0DB8::/126` and `2001:db8::/126`
  # are the same network but different bytes, so only one spelling may be committed.
  defp canonical_addr?(tuple, text) do
    List.to_string(:inet.ntoa(tuple)) == text
  rescue
    _ -> false
  end

  defp canonical_cidr?(tuple, bits, text) do
    List.to_string(:inet.ntoa(tuple)) <> "/" <> Integer.to_string(bits) == text
  rescue
    _ -> false
  end

  defp parse_addr(s) do
    case :inet.parse_strict_address(String.to_charlist(s)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Pack an address tuple into an integer: 8 bits per octet for IPv4, 16 per group for
  # IPv6, so masking works uniformly across both widths.
  defp addr_to_int(t) do
    shift = if tuple_size(t) == 4, do: 8, else: 16
    t |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, shift) + part end)
  end

  defp encode_page(p) do
    Serviceradar.Edge.V1.ScheduledPlanPageV1.encode(p)
  rescue
    _ -> :binary.copy(<<0>>, @max_plan_page_bytes + 1)
  end

  defp plan_root(h, pages) do
    if HashGrammar.plan_root(pages) == Map.get(h, :plan_root_sha256),
      do: :ok,
      else: {:error, :plan_root}
  end

  defp compute_windows(pages) do
    case HashGrammar.plan_mtr_windows(pages) do
      :error -> {:error, :mtr_window}
      ok -> ok
    end
  end

  defp mtr_commitment(h, pages) do
    case HashGrammar.plan_mtr_ordinal_range_commitment(pages) do
      :error ->
        {:error, :mtr_window}

      {:ok, want} ->
        if want == Map.get(h, :mtr_ordinal_range_commitment),
          do: :ok,
          else: {:error, :mtr_commitment}
    end
  end

  # Mirrors Go's ValidateCanonicalUUID exactly: 16 bytes, VERSION 1..8, RFC 4122
  # VARIANT (0b10xx), and not the all-zero value. Length-and-nonzero alone accepted
  # version-0, version-9 and non-RFC-variant identifiers that Go refuses.
  @doc false
  def canonical_uuid?(<<_::48, ver::4, _::12, var::2, _::62>> = v)
      when ver >= 1 and ver <= 8 and var == 2,
      do: byte_size(v) == @uuid_len and v != <<0::128>>

  def canonical_uuid?(_), do: false

  @doc false
  def uuidv7?(<<_::48, ver::4, _::12, var::2, _::62>> = v) when ver == 7 and var == 2,
    do: canonical_uuid?(v)

  def uuidv7?(_), do: false

  defp digest?(v), do: is_binary(v) and byte_size(v) == @sha256_len

  # Protobuf scalar DOMAINS. Sign checks alone let 2^32 into a uint32 field and 2^64
  # into a uint64 one -- values the wire cannot represent, so a validator that accepts
  # them is describing a message that cannot exist.
  defp uint32?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFF
  defp uint64?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFFFFFFFFFF

  defp bounded_bytes?(v, min, max),
    do: is_binary(v) and byte_size(v) >= min and byte_size(v) <= max
end
