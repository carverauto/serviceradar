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
    with :ok <- no_unknown(header),
         :ok <- Enum.reduce_while(pages, :ok, &halt_on_error(no_unknown(&1), &2)),
         :ok <- header_identity(header),
         :ok <- header_digest(header),
         :ok <- page_bounds(header, pages),
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
    nested = Enum.any?(Map.get(m, :ranges) || [], &(Map.get(&1, :__unknown_fields__, []) != []))

    if Map.get(m, :__unknown_fields__, []) == [] and not nested,
      do: :ok,
      else: {:error, :unknown_fields}
  end

  defp no_unknown(_), do: {:error, :unknown_fields}

  defp header_identity(h) do
    policy = Map.get(h, :availability_policy_id)

    if uuidv7?(Map.get(h, :execution_plan_id)) and
         Map.get(h, :digest_version) == @plan_digest_version and
         digest?(Map.get(h, :plan_root_sha256)) and
         digest?(Map.get(h, :check_set_sha256)) and
         canonical_uuid?(Map.get(h, :network_scope_id)) and
         bounded_bytes?(policy, 1, @max_policy_id_bytes) and
         is_integer(Map.get(h, :page_count)) and Map.get(h, :page_count) > 0 and
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

  defp page_bounds(h, pages) do
    cond do
      # A header declaring pages while supplying none is the case that made every
      # downstream check vacuous: with no pages, nothing is walked and nothing fails.
      pages == [] -> {:error, :page_bounds}
      length(pages) > @max_manifest_pages -> {:error, :page_bounds}
      Map.get(h, :page_count) != length(pages) -> {:error, :page_chain}
      true -> :ok
    end
  end

  defp pages_and_ranges(h, pages) do
    plan_id = Map.get(h, :execution_plan_id)
    header_check_set = Map.get(h, :check_set_sha256)
    header_policy = Map.get(h, :availability_policy_id)
    n = length(pages)

    pages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0, MapSet.new()}, fn {p, i}, {:ok, total, seen} ->
      ranges = Map.get(p, :ranges) || []
      prev = if i == 0, do: <<>>, else: Enum.at(pages, i - 1).page_sha256

      cond do
        Map.get(p, :digest_version) != @plan_digest_version ->
          {:halt, {:error, :digest_version}}

        Map.get(p, :execution_plan_id) != plan_id ->
          {:halt, {:error, :page_chain}}

        Map.get(p, :page_index) != i or Map.get(p, :page_count) != n ->
          {:halt, {:error, :page_chain}}

        (Map.get(p, :prev_page_sha256) || <<>>) != prev ->
          {:halt, {:error, :page_chain}}

        ranges == [] or length(ranges) > @max_ranges_per_page ->
          {:halt, {:error, :page_bounds}}

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
        # Reconcile the declared total: a resealed wrong total_target_count was
        # accepted before, so the header could claim coverage the pages do not have.
        if total == Map.get(h, :total_target_count), do: :ok, else: {:error, :plan_totals}

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

  defp validate_range(r, page_check_set, header_policy) do
    cidr = Map.get(r, :cidr) || ""
    first = Map.get(r, :first_address) || ""
    last = Map.get(r, :last_address) || ""
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

      byte_size(cidr) > @max_range_str_bytes ->
        {:error, :plan_range}

      byte_size(first) > @max_range_str_bytes ->
        {:error, :plan_range}

      byte_size(last) > @max_range_str_bytes ->
        {:error, :plan_range}

      has_cidr == has_span ->
        {:error, :plan_range}

      not is_integer(Map.get(r, :target_count)) ->
        {:error, :plan_range}

      Map.get(r, :target_count) == 0 ->
        {:error, :plan_range}

      not digest?(Map.get(r, :check_set_sha256)) ->
        {:error, :plan_range}

      Map.get(r, :check_set_sha256) != page_check_set ->
        {:error, :check_set}

      not bounded_bytes?(Map.get(r, :availability_policy_id), 0, @max_policy_id_bytes) ->
        {:error, :plan_range}

      Map.get(r, :availability_policy_id) != header_policy ->
        {:error, :plan_range}

      true ->
        span_matches(r, cidr, first, last)
    end
  end

  # The range expands to EXACTLY its address span, so the covered work set is
  # deterministic. Mirrors Go's rangeSpanSize, including the CANONICAL-SPELLING rule:
  # one network must not have two content digests.
  defp span_matches(r, cidr, first, last) do
    case span_size(cidr, first, last) do
      {:ok, size} ->
        if Map.get(r, :target_count) == size, do: :ok, else: {:error, :plan_range}

      :error ->
        {:error, :plan_range}
    end
  end

  defp span_size("", first, last) do
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

  defp span_size(cidr, _first, _last) do
    with [addr, bits] <- String.split(cidr, "/", parts: 2),
         {bits_int, ""} <- Integer.parse(bits),
         {:ok, a} <- parse_addr(addr),
         true <- canonical_addr?(a, addr) do
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

  defp bounded_bytes?(v, min, max),
    do: is_binary(v) and byte_size(v) >= min and byte_size(v) <= max
end
