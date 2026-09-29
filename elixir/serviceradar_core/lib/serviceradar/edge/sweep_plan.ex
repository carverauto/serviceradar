defmodule ServiceRadar.Edge.SweepPlan do
  @moduledoc """
  Builds the scheduled plan of one sweep execution from a group's static targets.

  A plan is what a source authorization binds: its header digest is
  `execution_plan_sha256` and each range's digest is a `target_range_sha256`. The ABI
  defines the digests and validates a plan, but nothing built one outside a Go test helper,
  so this is the producer. Its output is checked by `ServiceRadar.Edge.PlanValidate` before
  it is returned, and the digests are proven identical to Go's by
  `proto/edge/v1/testdata/sweep_static_plan_corpus.txt`.

  ## Ranges

  One `TargetRangeV1` per configured static target, never merged with another. A static
  target is a bare address or a CIDR; any other form makes the group ineligible. A bare IP
  becomes a `/32` or `/128` CIDR; a CIDR is committed as its canonical prefix (`10.1.2.3/24`
  is `10.1.2.0/24`). IPv4 is dotted-quad. IPv6 is RFC 5952 (lowercase, no leading zeros, the
  longest run of two or more zero groups compressed, the first such run on a tie) and is
  refused when that spelling differs from `:inet.ntoa/1`, so a returned plan is one both
  validators accept. An IPv6 prefix shorter than `/65` holds more addresses than a
  `target_count` can carry and is refused. Two spellings of the same target are one range.
  Ranges are ordered by address family, network address and prefix length, so the same
  targets always give the same plan for the same ids.

  A page holds at most 256 ranges (`MaxRangesPerPage`); a plan uses as many pages as it
  needs. Checks are ICMP and TCP only, so the MTR fields are zero.

  ## Checks

  `checks/2` turns a group's effective modes and ports into the `(mode, protocol, port)`
  set that `check_set_sha256` identifies. Callers pass the values the sweep compiler
  emits, after profile and override inheritance, not the group's own fields.
  """

  import Bitwise

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.TargetRangeV1

  @max_ranges_per_page 256
  @digest_version 1
  @availability_policy_id "any-success-v1"
  @u64_max 18_446_744_073_709_551_615

  # An IPv6 target may hold at most 2^63 addresses so that its count fits a uint64.
  @max_ipv6_host_bits 63

  # SweepMode and TransportProtocol enum values (proto/edge/v1/sweep.proto).
  @mode_icmp 1
  @mode_tcp_syn 2
  @mode_tcp_connect 3
  @protocol_icmp 1
  @protocol_tcp 2

  @type check :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type reason ::
          :no_targets
          | :no_checks
          | :no_ports
          | :mtr_unsupported
          | :plan_total_overflow
          | {:invalid_option, atom()}
          | {:unsupported_mode, String.t()}
          | {:invalid_port, term()}
          | {:invalid_target, String.t()}
          | {:target_too_wide, String.t()}
          | {:invalid_plan, atom()}

  @doc "The availability policy of a plan: a host is available when any of its checks succeeded."
  @spec availability_policy_id() :: binary()
  def availability_policy_id, do: @availability_policy_id

  @doc """
  The checks a group's effective modes and ports run: ICMP once, and each TCP mode on every
  port. `arp` and blank modes are ignored, as the agent ignores them; `mtr` is refused because
  a plan built here admits no MTR.
  """
  @spec checks([String.t()], [integer()]) :: {:ok, [check()]} | {:error, reason()}
  def checks(modes, ports) when is_list(modes) and is_list(ports) do
    with {:ok, kinds} <- mode_kinds(modes),
         {:ok, ports} <- normalize_ports(ports),
         :ok <- require_ports(kinds, ports) do
      case kinds |> Enum.flat_map(&expand_kind(&1, ports)) |> Enum.uniq() |> Enum.sort() do
        [] -> {:error, :no_checks}
        checks -> {:ok, checks}
      end
    end
  end

  @doc "The `check_set_sha256` of a set of checks."
  @spec check_set_sha256([check()]) :: binary()
  def check_set_sha256(checks), do: HashGrammar.check_set_digest(checks)

  @doc """
  The canonical form of one static target: its CIDR spelling, its address count, and the
  key ranges are ordered by.
  """
  @spec canonical_target(String.t()) ::
          {:ok, %{cidr: String.t(), count: pos_integer(), order: tuple()}} | {:error, reason()}
  def canonical_target(text) when is_binary(text) do
    trimmed = String.trim(text)
    [address | prefix] = String.split(trimmed, "/", parts: 2)

    with false <- String.contains?(trimmed, "%"),
         {:ok, tuple} <- parse_address(address),
         {family_bits, value} = to_integer(tuple),
         {:ok, bits} <- prefix_bits(prefix, family_bits) do
      host_bits = family_bits - bits

      if family_bits == 128 and host_bits > @max_ipv6_host_bits do
        {:error, {:target_too_wide, trimmed}}
      else
        network = value &&& bnot((1 <<< host_bits) - 1)

        case to_text(family_bits, network) do
          {:ok, text} ->
            {:ok,
             %{
               cidr: text <> "/" <> Integer.to_string(bits),
               count: 1 <<< host_bits,
               order: {family_bits, network, bits}
             }}

          :error ->
            {:error, {:invalid_target, trimmed}}
        end
      end
    else
      _ -> {:error, {:invalid_target, trimmed}}
    end
  end

  @doc """
  Builds the plan of one execution: `{:ok, %{header: header, pages: pages}}`.

  Options:

    * `:plan_id` - the 16-byte UUIDv7 of the plan (required);
    * `:network_scope_id` - the 16-byte scope the header binds (required);
    * `:check_set_sha256` - the 32-byte identity of the checks (required);
    * `:range_id` - a zero-arity function returning a fresh 16-byte range id
      (default: a random UUID).

  Any failure is a typed error and no plan; the plan is validated before it is returned.
  """
  @spec build([String.t()], keyword()) ::
          {:ok, %{header: struct(), pages: [struct()]}}
          | {:error, reason()}
  def build(targets, opts) when is_list(targets) and is_list(opts) do
    with {:ok, plan_id} <- fetch_bytes(opts, :plan_id, 16),
         {:ok, scope} <- fetch_bytes(opts, :network_scope_id, 16),
         {:ok, check_set} <- fetch_bytes(opts, :check_set_sha256, 32),
         {:ok, canonical} <- canonicalize(targets),
         range_id = Keyword.get(opts, :range_id, fn -> Ecto.UUID.bingenerate() end),
         ranges = Enum.map(canonical, &range(&1, check_set, range_id.())),
         pages = pages(ranges, plan_id, check_set),
         {:ok, header} <- header(pages, ranges, plan_id, scope, check_set),
         :ok <- validate(header, pages) do
      {:ok, %{header: header, pages: pages}}
    end
  end

  defp mode_kinds(modes) do
    Enum.reduce_while(modes, {:ok, []}, fn mode, {:ok, acc} ->
      case mode |> to_string() |> String.trim() |> String.downcase() do
        "icmp" -> {:cont, {:ok, [:icmp | acc]}}
        "tcp" -> {:cont, {:ok, [:tcp_syn | acc]}}
        "tcp_connect" -> {:cont, {:ok, [:tcp_connect | acc]}}
        "mtr" -> {:halt, {:error, :mtr_unsupported}}
        blank when blank in ["", "arp"] -> {:cont, {:ok, acc}}
        other -> {:halt, {:error, {:unsupported_mode, other}}}
      end
    end)
  end

  defp normalize_ports(ports) do
    result =
      Enum.reduce_while(ports, {:ok, []}, fn
        port, {:ok, acc} when is_integer(port) and port >= 1 and port <= 65_535 ->
          {:cont, {:ok, [port | acc]}}

        port, _acc ->
          {:halt, {:error, {:invalid_port, port}}}
      end)

    case result do
      {:ok, ports} -> {:ok, ports |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp require_ports(kinds, []) do
    if Enum.any?(kinds, &(&1 in [:tcp_syn, :tcp_connect])), do: {:error, :no_ports}, else: :ok
  end

  defp require_ports(_kinds, _ports), do: :ok

  defp expand_kind(:icmp, _ports), do: [{@mode_icmp, @protocol_icmp, 0}]
  defp expand_kind(:tcp_syn, ports), do: Enum.map(ports, &{@mode_tcp_syn, @protocol_tcp, &1})

  defp expand_kind(:tcp_connect, ports),
    do: Enum.map(ports, &{@mode_tcp_connect, @protocol_tcp, &1})

  defp parse_address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> :error
    end
  end

  defp to_integer({a, b, c, d}), do: {32, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp to_integer(words) when tuple_size(words) == 8 do
    value =
      words
      |> Tuple.to_list()
      |> Enum.reduce(0, fn word, acc -> acc <<< 16 ||| word end)

    {128, value}
  end

  defp to_text(32, value) do
    <<a, b, c, d>> = <<value::32>>
    {:ok, List.to_string(:inet.ntoa({a, b, c, d}))}
  end

  defp to_text(128, value) do
    words = for <<(word::16 <- <<value::128>>)>>, do: word
    rfc5952 = format_ipv6(words)
    inet = words |> List.to_tuple() |> :inet.ntoa() |> List.to_string()

    if rfc5952 == inet, do: {:ok, rfc5952}, else: :error
  end

  defp format_ipv6([0, 0, 0, 0, 0, 0xFFFF, high, low]) do
    {:ok, dotted} = to_text(32, high <<< 16 ||| low)
    "::ffff:" <> dotted
  end

  defp format_ipv6(words) do
    case longest_zero_run(words) do
      {_start, length} when length < 2 ->
        hex_groups(words)

      {start, length} ->
        head = words |> Enum.take(start) |> hex_groups()
        tail = words |> Enum.drop(start + length) |> hex_groups()
        head <> "::" <> tail
    end
  end

  defp hex_groups(words) do
    Enum.map_join(words, ":", &(&1 |> Integer.to_string(16) |> String.downcase()))
  end

  defp longest_zero_run(words) do
    {start, length, _, _} =
      words
      |> Enum.with_index()
      |> Enum.reduce({0, 0, nil, 0}, fn
        {0, index}, {best_start, best_length, nil, _} ->
          {best_start, best_length, index, 1}

        {0, _index}, {best_start, best_length, run_start, run_length} ->
          run_length = run_length + 1

          if run_length > best_length do
            {run_start, run_length, run_start, run_length}
          else
            {best_start, best_length, run_start, run_length}
          end

        {_word, _index}, {best_start, best_length, _, _} ->
          {best_start, best_length, nil, 0}
      end)

    {start, length}
  end

  defp prefix_bits([], family_bits), do: {:ok, family_bits}

  defp prefix_bits([text], family_bits) do
    case Integer.parse(text) do
      {bits, ""} when bits >= 0 and bits <= family_bits -> {:ok, bits}
      _ -> :error
    end
  end

  defp canonicalize([]), do: {:error, :no_targets}

  defp canonicalize(targets) do
    result =
      Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
        case canonical_target(to_string(target)) do
          {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, canonical} -> {:ok, canonical |> Enum.uniq_by(& &1.cidr) |> Enum.sort_by(& &1.order)}
      error -> error
    end
  end

  defp range(%{cidr: cidr, count: count}, check_set, range_id) do
    range = %TargetRangeV1{
      range_id: range_id,
      cidr: cidr,
      target_count: count,
      check_set_sha256: check_set,
      availability_policy_id: @availability_policy_id,
      mtr_admission_budget: 0,
      mtr_ordinal_count: 0
    }

    %{range | range_sha256: HashGrammar.range_digest(range)}
  end

  defp pages(ranges, plan_id, check_set) do
    chunks = Enum.chunk_every(ranges, @max_ranges_per_page)
    page_count = length(chunks)

    {pages, _prev} =
      chunks
      |> Enum.with_index()
      |> Enum.map_reduce("", fn {chunk, index}, prev ->
        page = %ScheduledPlanPageV1{
          execution_plan_id: plan_id,
          page_index: index,
          page_count: page_count,
          prev_page_sha256: prev,
          check_set_sha256: check_set,
          digest_version: @digest_version,
          ranges: chunk
        }

        page = %{page | page_sha256: HashGrammar.plan_page_digest(page)}
        {page, page.page_sha256}
      end)

    pages
  end

  defp header(pages, ranges, plan_id, scope, check_set) do
    total = ranges |> Enum.map(& &1.target_count) |> Enum.sum()

    with true <- total <= @u64_max or {:error, :plan_total_overflow},
         {:ok, commitment} <- mtr_commitment(pages) do
      header = %ScheduledPlanHeaderV1{
        execution_plan_id: plan_id,
        page_count: length(pages),
        total_target_count: total,
        plan_root_sha256: HashGrammar.plan_root(pages),
        digest_version: @digest_version,
        check_set_sha256: check_set,
        availability_policy_id: @availability_policy_id,
        network_scope_id: scope,
        mtr_ordinal_range_commitment: commitment
      }

      {:ok, %{header | execution_plan_sha256: HashGrammar.plan_header_digest(header)}}
    end
  end

  defp mtr_commitment(pages) do
    case HashGrammar.plan_mtr_ordinal_range_commitment(pages) do
      {:ok, commitment} -> {:ok, commitment}
      :error -> {:error, {:invalid_plan, :mtr_window}}
    end
  end

  defp validate(header, pages) do
    case PlanValidate.validate(header, pages) do
      {:ok, _windows} -> :ok
      {:error, reason} -> {:error, {:invalid_plan, reason}}
    end
  end

  defp fetch_bytes(opts, key, size) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and byte_size(value) == size -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end
end
