defmodule ServiceRadar.Edge.SweepBodyValidate do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord.ValidateSweepObservationBatch` (task 1.2-c).

  Fail-closes a `SweepObservationBatchV1`: known source, the `source_run_id` disposition its
  source dictates, present and well-formed identity, a non-empty non-duplicate check set
  whose derived bitmask equals `configured_mode_bits`, and per host a result bitmask that is
  a subset of configured, a summary present for exactly the named modes, in-range
  open-port/error indices, and a 4/16-byte address.

  ## The ingress is `validate_bytes/1`

  `validate_bytes/1` is the composed, fail-closed entry point: extracted bytes -> the
  curated `WireDecode.decode_sweep_batch/1` (work ceiling, recursive wire hygiene, unknown
  fields and groups) -> this validator. `validate/1` is the DECODED stage. It is public
  because the vectors address it directly, but a caller holding bytes must use
  `validate_bytes/1`: only the decoder can see what the wire carried.

  ## Two passes, and where they interleave

  The structural pass checks, per message: the EXACT generated field set, no retained
  unknown fields, per-field Elixir type, PROTOBUF WIDTH, and proper (non-improper) lists.
  Most of that has NO Go peer, and that is not an omission -- Go's generated struct makes
  those states unrepresentable. `BatchSequence` is a `uint64`, so `2^64` cannot be assigned
  and no validator can be asked about it; in Elixir every message is a plain struct over
  `term()`, so a hand-built value can carry `2^64`, a float where an integer belongs, or an
  improper list. Without this pass Elixir accepts records Go cannot represent -- and that
  the wire cannot carry either.

  The semantic pass mirrors Go's ORDER, because a body can violate several rules at once and
  the reported reason is whichever is noticed first.

  The two INTERLEAVE at exactly one point, deliberately: per-host structure is checked AFTER
  the semantic prefix. `MaxSweepHostsPerBatch` is a WORK bound, and a 32 MiB body can hold
  millions of empty hosts, so validating them all and then reporting "too many" is the
  traversal the bound exists to prevent. Enforcing it at Go's position also preserves Go's
  precedence: an over-long host list on a batch with an unknown source reports the source.

  ## Reasons

  `{family, detail}`. The FAMILY is the portable half: each maps to exactly one Go sentinel
  (`family_to_go_sentinel/0` pins the mapping), except `:shape` and `:width`, which are
  Elixir-side preconditions with no Go peer for the reason above. The DETAIL is local and is
  NOT claimed as cross-language parity: Go's detail is a formatted string suffix.

  ## Every domain here is borrowed, never restated

  Admitted enum members come from `SemanticValidate.enum_field_policy/0`, the allocated-MTR
  subset from `SweepOutcomePolicy`, the source matrix from `SweepMatrix`, mode-bit NUMBERS
  from the generated `SweepModeBit`, and each enum's atom domain from that enum's own
  generated `mapping/0`. A second copy of any of those would have to be held in numeric
  parity by hand.

  `SweepOutcomePolicy` is deliberately NEUTRAL -- it depends on neither this module nor
  `SweepCorrelate`. Reading the policy off `SweepCorrelate` would make this module depend on
  the correlation module, and step 3 routes this one INTO that one: a mutual edge, and not
  the one-way edge the ledger records.
  """

  import Bitwise

  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias ServiceRadar.Edge.SweepMatrix
  alias ServiceRadar.Edge.SweepOutcomePolicy
  alias Serviceradar.Edge.V1, as: V1
  alias ServiceRadar.Edge.WireDecode

  @type family ::
          :shape
          | :width
          | :source
          | :source_run_id
          | :identity
          | :checks
          | :bounds
          | :mode_bits
          | :mode_summary
          | :address
          | :check_index
          | :summary
  @type reason :: {family(), atom()}

  # Mirrors go/pkg/edge/edgerecord/domain.go:36.
  @max_hosts_per_batch 2000
  @sha256_len 32

  # Protobuf integer widths. Enumerated SEPARATELY on purpose: a `uint32` field guarded
  # against the `uint64` ceiling accepts 2^32, which the wire cannot carry.
  @u32_max 4_294_967_295
  @u64_max 18_446_744_073_709_551_615
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  # int32 is the width of every ENUM field on the wire, and is reachable only there: proto3
  # enums are OPEN, so an unrecognized value decodes to a bare integer.
  @i32_min -2_147_483_648
  @i32_max 2_147_483_647

  # What protobuf-elixir yields for the IEEE bit patterns an Erlang float cannot hold.
  @double_specials [:nan, :infinity, :negative_infinity]

  # The mode -> mode-bit CORRESPONDENCE. Only the correspondence is stated here; the numeric
  # values come from the generated `SweepModeBit`, so renumbering a bit moves this validator
  # with Go instead of leaving a stale literal behind.
  @mode_to_bit %{
    SWEEP_MODE_ICMP: :SWEEP_MODE_BIT_ICMP,
    SWEEP_MODE_TCP_SYN: :SWEEP_MODE_BIT_TCP_SYN,
    SWEEP_MODE_TCP_CONNECT: :SWEEP_MODE_BIT_TCP_CONNECT,
    SWEEP_MODE_MTR: :SWEEP_MODE_BIT_MTR
  }

  # The protocol/port partition of the admitted mode set. Genuinely local -- no descriptor
  # states which modes ride TCP -- and pinned as an EXACT partition of the admitted set, so
  # a new mode cannot land in neither arm.
  @tcp_modes [:SWEEP_MODE_TCP_SYN, :SWEEP_MODE_TCP_CONNECT]
  @icmp_modes [:SWEEP_MODE_ICMP, :SWEEP_MODE_MTR]

  # The eight messages this validator walks. Their generated key sets and enum atom domains
  # are resolved HERE, at compile time, from the same descriptors the inventory test pins --
  # so a proto change moves them, and the per-message hot path stays allocation-free.
  @messages [
    V1.SweepObservationBatchV1,
    V1.SweepTestV1,
    V1.SweepHostObservationV1,
    V1.SweepIcmpSummaryV1,
    V1.SweepTcpSummaryV1,
    V1.SweepMtrSummaryV1,
    V1.SweepOpenPortV1,
    V1.SweepPortErrorV1
  ]

  @generated_keys Map.new(@messages, fn mod -> {mod, mod |> struct() |> Map.keys()} end)

  @generated_enum_atoms (for mod <- @messages,
                             {_fnum, fp} <- mod.__message_props__().field_props,
                             match?({:enum, _}, fp.type),
                             into: %{} do
                           {:enum, enum_mod} = fp.type
                           {{mod, fp.name_atom}, Map.keys(enum_mod.mapping())}
                         end)

  @doc """
  FAMILY -> Go sentinel. Data rather than prose, so the vectors assert the exact mapping.

  `:shape` and `:width` map to NOTHING deliberately -- see the moduledoc.
  """
  @spec family_to_go_sentinel() :: %{family() => String.t() | nil}
  def family_to_go_sentinel do
    %{
      shape: nil,
      width: nil,
      source: "ErrSweepSource",
      source_run_id: "ErrSweepSourceRunID",
      identity: "ErrSweepIdentity",
      checks: "ErrSweepChecks",
      bounds: "ErrSweepBounds",
      mode_bits: "ErrSweepModeBits",
      mode_summary: "ErrSweepModeSummary",
      address: "ErrSweepAddress",
      check_index: "ErrSweepCheckIndex",
      summary: "ErrSweepSummary"
    }
  end

  @doc "The mode -> mode-bit correspondence; the NUMBERS live in the generated enum."
  @spec mode_bit_names() :: %{atom() => atom()}
  def mode_bit_names, do: @mode_to_bit

  @doc "The protocol partition of the admitted mode set, as `{tcp_modes, icmp_modes}`."
  @spec mode_partition() :: {[atom()], [atom()]}
  def mode_partition, do: {@tcp_modes, @icmp_modes}

  @doc "The frozen host ceiling, mirroring Go's `MaxSweepHostsPerBatch`."
  @spec max_hosts_per_batch() :: pos_integer()
  def max_hosts_per_batch, do: @max_hosts_per_batch

  @doc """
  The composed ingress: extracted bytes -> curated decode -> body validation.

  This is the fail-closed entry point; `validate/1` alone cannot see what the wire carried.

  Returns the VALIDATED batch, as the other raw validators do. Returning a bare `:ok` would
  force every caller to decode a second time or to bypass this function and compose the two
  stages itself -- which is exactly the seam this exists to remove.
  """
  @spec validate_bytes(term()) ::
          {:ok, V1.SweepObservationBatchV1.t()} | {:error, reason() | WireDecode.reason()}
  def validate_bytes(bytes) do
    case WireDecode.decode_sweep_batch(bytes) do
      {:ok, batch} ->
        case validate(batch) do
          :ok -> {:ok, batch}
          {:error, _} = e -> e
        end

      {:error, _} = e ->
        propagate_decode_error(e)
    end
  end

  @doc """
  The decode-ERROR propagation used by `validate_bytes/1`, exposed so all four decoder
  reasons can be pinned directly.

  `:not_ready` needs an unloaded schema module and `:too_large` a 32 MiB input, so proving
  propagation through `validate_bytes/1` alone would either miss reasons or need a seam in
  the decoder. It is ERROR-ONLY on purpose: a helper that also built `{:ok, batch}` would be
  a public way to mint a "validated" batch that never passed through the decoder.
  """
  @spec propagate_decode_error({:error, WireDecode.reason()}) :: {:error, WireDecode.reason()}
  def propagate_decode_error({:error, reason}), do: {:error, reason}

  @doc """
  Validates a DECODED batch. `term()` because the argument is whatever a decoder or caller
  produced; a shape this never saw returns `{:error, reason}`, never a raise.
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(%V1.SweepObservationBatchV1{} = b) do
    with :ok <- structural_batch(b),
         :ok <- source_and_disposition(b),
         :ok <- identity(b),
         {:ok, configured} <- checks(b),
         :ok <- configured_matches(b, configured),
         :ok <- repeated_elements(b, :hosts, &structural_host/1) do
      hosts(b, configured)
    end
  end

  def validate(_), do: {:error, {:shape, :not_a_batch}}

  # =====================================================================================
  # PASS 1 -- structure and width.
  # =====================================================================================

  # Everything EXCEPT per-host structure, which waits for the host ceiling.
  defp structural_batch(b) do
    with :ok <- message_frame(b),
         :ok <-
           bytes_fields(b, [
             :execution_id,
             :sweep_group_id,
             :execution_plan_id,
             :execution_plan_sha256,
             :target_range_id,
             :target_range_sha256,
             :availability_policy_id,
             :source_run_id
           ]),
         :ok <- u32_fields(b, [:execution_shard, :configured_mode_bits]),
         :ok <- u64_fields(b, [:assignment_epoch, :batch_sequence]),
         :ok <- i64_fields(b, [:observed_at_unix_nano]),
         :ok <- enum_field(b, :source),
         :ok <- list_field(b, :hosts) do
      repeated_elements(b, :tested_checks, &structural_check/1)
    end
  end

  # The generated field set EXACTLY, and no retained unknown fields.
  #
  # `%Mod{}` in a pattern compiles to `%{__struct__: Mod}`, so an extra key survives every
  # struct match; comparing the key set is what refuses it. Unknown fields are checked here,
  # inside the traversal that already visits every message, rather than by a second
  # recursive walker.
  defp message_frame(%mod{} = m) do
    cond do
      Map.get(m, :__unknown_fields__) != [] ->
        {:error, {:shape, :unknown_fields}}

      not exact_fields?(m, mod) ->
        {:error, {:shape, :extra_fields}}

      true ->
        :ok
    end
  end

  # Equal SIZE plus every generated key PRESENT is exactly equal key sets, by pigeonhole --
  # and it costs no allocation. Comparing sorted key lists instead meant building the
  # expected struct, listing its keys and sorting, on EVERY message; at 2000 hosts that is
  # ~10k needless struct allocations per batch.
  defp exact_fields?(m, mod) do
    known = Map.fetch!(@generated_keys, mod)
    map_size(m) == length(known) and Enum.all?(known, &Map.has_key?(m, &1))
  end

  defp structural_check(%V1.SweepTestV1{} = c) do
    with :ok <- message_frame(c),
         :ok <- enum_field(c, :mode),
         :ok <- enum_field(c, :protocol) do
      u32_fields(c, [:port])
    end
  end

  defp structural_check(_), do: {:error, {:shape, :tested_check}}

  defp structural_host(%V1.SweepHostObservationV1{} = h) do
    with :ok <- message_frame(h),
         :ok <- bytes_fields(h, [:address]),
         :ok <- string_fields(h, [:hostname]),
         :ok <- sint64_fields(h, [:observed_at_delta_nano]),
         :ok <- optional_sint64_fields(h, [:first_seen_delta_nano, :last_seen_delta_nano]),
         :ok <- u32_fields(h, [:result_mode_bits, :mode_revision]),
         :ok <- optional_message(h, :icmp, V1.SweepIcmpSummaryV1, &structural_icmp/1),
         :ok <- optional_message(h, :tcp, V1.SweepTcpSummaryV1, &structural_tcp/1),
         :ok <- optional_message(h, :mtr, V1.SweepMtrSummaryV1, &structural_mtr/1),
         :ok <- repeated_elements(h, :open_ports, &structural_open_port/1) do
      repeated_elements(h, :port_errors, &structural_port_error/1)
    end
  end

  defp structural_host(_), do: {:error, {:shape, :host}}

  defp structural_icmp(s) do
    with :ok <- message_frame(s),
         :ok <- enum_field(s, :outcome),
         :ok <- bool_fields(s, [:target_reached]),
         :ok <- optional_u64_fields(s, [:round_trip_micro]),
         :ok <- optional_double_fields(s, [:packet_loss_pct]) do
      u32_fields(s, [:sent, :received])
    end
  end

  defp structural_tcp(s) do
    with :ok <- message_frame(s),
         :ok <- enum_field(s, :outcome) do
      u32_fields(s, [:tested_count, :open_count])
    end
  end

  defp structural_mtr(s) do
    with :ok <- message_frame(s),
         :ok <- bytes_fields(s, [:trace_id]),
         :ok <- enum_field(s, :outcome),
         :ok <- bool_fields(s, [:target_reached]),
         :ok <- optional_u64_fields(s, [:final_rtt_micro]),
         :ok <- optional_double_fields(s, [:packet_loss_pct]),
         :ok <- u32_fields(s, [:total_hops]) do
      string_fields(s, [:error_code])
    end
  end

  defp structural_open_port(%V1.SweepOpenPortV1{} = p) do
    with :ok <- message_frame(p),
         :ok <- u32_fields(p, [:tested_check_index]),
         :ok <- optional_u64_fields(p, [:response_time_nano]) do
      string_fields(p, [:service])
    end
  end

  defp structural_open_port(_), do: {:error, {:shape, :open_port}}

  defp structural_port_error(%V1.SweepPortErrorV1{} = p) do
    with :ok <- message_frame(p),
         :ok <- u32_fields(p, [:tested_check_index]) do
      string_fields(p, [:error_code])
    end
  end

  defp structural_port_error(_), do: {:error, {:shape, :port_error}}

  # --- per-width field checks -----------------------------------------------------------
  # One helper per PROTOBUF WIDTH rather than one generic integer helper. A single
  # "is it an integer in range" check invites reusing the widest ceiling.

  defp u32_fields(m, keys), do: each(keys, &int_in(m, &1, 0, @u32_max, :uint32))
  defp u64_fields(m, keys), do: each(keys, &int_in(m, &1, 0, @u64_max, :uint64))
  defp i64_fields(m, keys), do: each(keys, &int_in(m, &1, @i64_min, @i64_max, :int64))

  # sint64 spans the SAME range as int64 -- they differ in ENCODING (zigzag), not domain.
  # It still gets its own helper and its own reported width: collapsing them makes a field's
  # rejection name a type the proto does not give it, and whoever widens one helper later
  # silently widens the other.
  defp sint64_fields(m, keys), do: each(keys, &int_in(m, &1, @i64_min, @i64_max, :sint64))

  defp optional_u64_fields(m, keys), do: each(keys, &optional_int_in(m, &1, 0, @u64_max, :uint64))

  defp optional_sint64_fields(m, keys),
    do: each(keys, &optional_int_in(m, &1, @i64_min, @i64_max, :sint64))

  defp int_in(m, key, lo, hi, width) do
    case Map.get(m, key) do
      v when is_integer(v) and v >= lo and v <= hi -> :ok
      v when is_integer(v) -> {:error, {:width, width}}
      _ -> {:error, {:shape, width}}
    end
  end

  defp optional_int_in(m, key, lo, hi, width) do
    # `nil` is ABSENT, a distinct state from a present zero for these fields.
    if Map.get(m, key) == nil, do: :ok, else: int_in(m, key, lo, hi, width)
  end

  defp optional_double_fields(m, keys) do
    each(keys, fn key ->
      case Map.get(m, key) do
        nil ->
          :ok

        v when is_float(v) ->
          :ok

        # NOT a shape error. An Erlang float is NEVER NaN or infinite, so protobuf-elixir
        # decodes those IEEE bit patterns to these three ATOMS. They are wire-reachable
        # values of a `double` field, and rejecting them here would report `:shape` where Go
        # reports its summary sentinel. The DOMAIN rule refuses them.
        v when v in @double_specials ->
          :ok

        _ ->
          {:error, {:shape, :double}}
      end
    end)
  end

  defp bytes_fields(m, keys) do
    each(keys, fn key ->
      if is_binary(Map.get(m, key)), do: :ok, else: {:error, {:shape, :bytes}}
    end)
  end

  defp string_fields(m, keys) do
    each(keys, fn key ->
      case Map.get(m, key) do
        v when is_binary(v) ->
          # A proto `string` is UTF-8 by definition; Go refuses invalid UTF-8 at decode, so
          # only a hand-built struct holds it here.
          if String.valid?(v), do: :ok, else: {:error, {:shape, :string_utf8}}

        _ ->
          {:error, {:shape, :string}}
      end
    end)
  end

  defp bool_fields(m, keys) do
    each(keys, fn key ->
      if is_boolean(Map.get(m, key)), do: :ok, else: {:error, {:shape, :bool}}
    end)
  end

  # An enum field holds either a GENERATED atom or, because proto3 enums are OPEN, a bare
  # int32 the decoder did not recognize. An arbitrary atom is neither: the generated encoder
  # cannot represent `:FUTURE`, so it can only come from a hand-built struct. Whether a
  # generated member is ADMITTED is a domain question, answered by the semantic pass.
  defp enum_field(%mod{} = m, key) do
    case Map.get(m, key) do
      v when is_atom(v) and not is_nil(v) ->
        if v in generated_enum_atoms(mod, key), do: :ok, else: {:error, {:shape, :enum}}

      v when is_integer(v) and v >= @i32_min and v <= @i32_max ->
        :ok

      v when is_integer(v) ->
        {:error, {:width, :enum_int32}}

      _ ->
        {:error, {:shape, :enum}}
    end
  end

  # Resolved at COMPILE time from the same descriptors. Doing it per call meant a props
  # lookup and a fresh key list for every enum field of every host.
  defp generated_enum_atoms(mod, key), do: Map.fetch!(@generated_enum_atoms, {mod, key})

  defp optional_message(m, key, mod, fun) do
    case Map.get(m, key) do
      nil -> :ok
      %^mod{} = v -> fun.(v)
      _ -> {:error, {:shape, key}}
    end
  end

  # A list field's SHAPE only. Element structure is separate, so the host ceiling can run
  # between the two.
  defp list_field(m, key) do
    if is_list(Map.get(m, key)), do: :ok, else: {:error, {:shape, key}}
  end

  defp repeated_elements(m, key, fun) do
    with :ok <- list_field(m, key),
         {:ok, _n} <- proper_length(Map.get(m, key)) do
      each(Map.get(m, key), fun)
    else
      :improper -> {:error, {:shape, :improper_list}}
      {:error, _} = e -> e
    end
  end

  # `is_list([1 | :tail])` is TRUE, and `Enum.reduce_while/3` then raises on the tail. A
  # function promising `{:error, reason}` must not raise on a shape it did not anticipate,
  # so the list is walked to its tail before any element work.
  #
  # UNBOUNDED, AND THAT IS A KNOWN LIMIT RATHER THAN A JUSTIFIED ONE. `repeated_elements/3`
  # runs for several list fields and only the host list sits behind a count ceiling. The
  # others are bounded on the WIRE by the decoder's byte limits -- which says nothing about a
  # hand-built struct, the shape this pass exists to reject. The properness walk is therefore
  # unbounded for those fields; per-field count ceilings are what would fix it, and none are
  # frozen today.
  defp proper_length(l), do: BoundedList.count_all(l)

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # =====================================================================================
  # PASS 2 -- semantics, in Go's order.
  # =====================================================================================

  defp source_and_disposition(b) do
    case SweepMatrix.fetch(b.source) do
      {:ok, rule} ->
        # Decided HERE, not in correlation: a function of two fields of THIS message that
        # consults no signed authority.
        case SweepMatrix.check_source_run_id(rule, b.source_run_id) do
          :ok -> :ok
          {:error, label} -> {:error, {:source_run_id, label}}
        end

      :error ->
        {:error, {:source, :unknown}}
    end
  end

  defp identity(b) do
    cond do
      not (uuid?(b.execution_id) and uuid?(b.execution_plan_id) and uuid?(b.target_range_id)) ->
        {:error, {:identity, :ids}}

      byte_size(b.execution_plan_sha256) != @sha256_len or
          byte_size(b.target_range_sha256) != @sha256_len ->
        {:error, {:identity, :plan_range_digest}}

      b.availability_policy_id == "" or b.batch_sequence == 0 or
          b.observed_at_unix_nano <= 0 ->
        {:error, {:identity, :policy_sequence_timestamp}}

      true ->
        :ok
    end
  end

  defp checks(b) do
    if b.tested_checks == [] do
      {:error, {:checks, :empty}}
    else
      with :ok <- host_ceiling(b), do: fold_checks(b.tested_checks)
    end
  end

  # Go's position for the bound, and the last point before anything walks the hosts.
  defp host_ceiling(b) do
    case BoundedList.count_at_most(b.hosts, @max_hosts_per_batch) do
      {:ok, _n} -> :ok
      :over -> {:error, {:bounds, :hosts}}
      :improper -> {:error, {:shape, :improper_list}}
    end
  end

  defp fold_checks(checks) do
    checks
    |> Enum.reduce_while({:ok, 0, MapSet.new()}, fn c, {:ok, bits, seen} ->
      key = {c.mode, c.protocol, c.port}

      cond do
        mode_bit(c.mode) == 0 -> {:halt, {:error, {:checks, :unknown_mode}}}
        not mode_protocol_consistent?(c) -> {:halt, {:error, {:checks, :mode_protocol_port}}}
        MapSet.member?(seen, key) -> {:halt, {:error, {:checks, :duplicate}}}
        true -> {:cont, {:ok, bits ||| mode_bit(c.mode), MapSet.put(seen, key)}}
      end
    end)
    |> case do
      {:ok, bits, _seen} -> {:ok, bits}
      {:error, _} = e -> e
    end
  end

  defp configured_matches(b, configured) do
    if b.configured_mode_bits == configured, do: :ok, else: {:error, {:mode_bits, :configured}}
  end

  defp hosts(b, configured) do
    # A TUPLE, so an index lookup is O(1) and cannot silently walk the list per entry.
    checks = List.to_tuple(b.tested_checks)
    each(b.hosts, &host(&1, checks, configured))
  end

  defp host(h, checks, configured) do
    with :ok <- address(h),
         :ok <- result_bits(h, configured),
         :ok <- summaries_named(h),
         :ok <- summaries(h),
         :ok <- check_indices(h, checks) do
      open_port_count(h)
    end
  end

  defp address(h) do
    if byte_size(h.address) in [4, 16], do: :ok, else: {:error, {:address, :length}}
  end

  defp result_bits(h, configured) do
    rmb = h.result_mode_bits

    if rmb == 0 or (rmb &&& bnot(configured)) != 0,
      do: {:error, {:mode_bits, :result}},
      else: :ok
  end

  # A summary must be present for EVERY named mode and absent for every unnamed one. Both
  # directions matter: a summary for a mode the fragment does not claim is unattributable.
  defp summaries_named(h) do
    rmb = h.result_mode_bits
    icmp = mode_bit(:SWEEP_MODE_ICMP)
    tcp = mode_bit(:SWEEP_MODE_TCP_SYN) ||| mode_bit(:SWEEP_MODE_TCP_CONNECT)
    mtr = mode_bit(:SWEEP_MODE_MTR)

    cond do
      named?(rmb, icmp) and is_nil(h.icmp) -> {:error, {:mode_summary, :icmp_missing}}
      named?(rmb, tcp) and is_nil(h.tcp) -> {:error, {:mode_summary, :tcp_missing}}
      named?(rmb, mtr) and is_nil(h.mtr) -> {:error, {:mode_summary, :mtr_missing}}
      not named?(rmb, icmp) and not is_nil(h.icmp) -> {:error, {:mode_summary, :icmp_unnamed}}
      not named?(rmb, tcp) and not is_nil(h.tcp) -> {:error, {:mode_summary, :tcp_unnamed}}
      not named?(rmb, mtr) and not is_nil(h.mtr) -> {:error, {:mode_summary, :mtr_unnamed}}
      true -> :ok
    end
  end

  defp named?(rmb, bits), do: (rmb &&& bits) != 0

  defp summaries(h) do
    with :ok <- icmp_summary(h.icmp),
         :ok <- tcp_summary(h.tcp) do
      mtr_summary(h.mtr)
    end
  end

  defp icmp_summary(nil), do: :ok

  defp icmp_summary(s) do
    cond do
      not admitted?(V1.SweepIcmpSummaryV1, :outcome, s.outcome) ->
        {:error, {:summary, :icmp_outcome}}

      s.received > s.sent ->
        {:error, {:summary, :icmp_received_gt_sent}}

      not valid_loss_pct?(s.packet_loss_pct) ->
        {:error, {:summary, :icmp_loss}}

      s.target_reached and s.received == 0 ->
        {:error, {:summary, :icmp_reached_zero_received}}

      true ->
        :ok
    end
  end

  defp tcp_summary(nil), do: :ok

  defp tcp_summary(s) do
    cond do
      not admitted?(V1.SweepTcpSummaryV1, :outcome, s.outcome) ->
        {:error, {:summary, :tcp_outcome}}

      s.open_count > s.tested_count ->
        {:error, {:summary, :tcp_open_gt_tested}}

      true ->
        :ok
    end
  end

  defp mtr_summary(nil), do: :ok

  defp mtr_summary(s) do
    allocated? = SweepOutcomePolicy.trace_allocated?(s.outcome)

    cond do
      not admitted?(V1.SweepMtrSummaryV1, :outcome, s.outcome) ->
        {:error, {:summary, :mtr_outcome}}

      # A trace id is present ONLY for allocated outcomes. NOT_ADMITTED / QUARANTINED /
      # SCHEDULER_LOST allocate no trace and must carry none.
      allocated? and not uuidv7?(s.trace_id) ->
        {:error, {:summary, :mtr_trace_id}}

      not allocated? and s.trace_id != "" ->
        {:error, {:summary, :mtr_unallocated_trace_id}}

      not valid_loss_pct?(s.packet_loss_pct) ->
        {:error, {:summary, :mtr_loss}}

      s.target_reached and s.total_hops == 0 ->
        {:error, {:summary, :mtr_reached_zero_hops}}

      true ->
        :ok
    end
  end

  # Absent is fine; present must be a real number in [0,100], which is Go's `validLossPct`.
  #
  # Go rejects NaN and the infinities with `IsNaN`/`IsInf` before its range test, because
  # there they are float64 values and every comparison against NaN is false. Elixir reaches
  # the same three by a different route -- they are not representable as Erlang floats, so
  # the decoder yields atoms, and an atom would pass an unguarded comparison for the
  # opposite reason (term ordering puts atoms above numbers). Neither runtime gets it free.
  defp valid_loss_pct?(nil), do: true
  defp valid_loss_pct?(v) when v in @double_specials, do: false
  defp valid_loss_pct?(v) when is_float(v), do: v >= 0.0 and v <= 100.0
  defp valid_loss_pct?(_), do: false

  # An open-port/error entry MUST reference a TCP check whose bit is in THIS fragment's
  # result bits, and each index may appear at most once ACROSS both lists -- an index that
  # is both open and errored is a conflicting claim about the same port.
  defp check_indices(h, checks) do
    n_checks = tuple_size(checks)

    entries =
      Enum.map(h.open_ports, & &1.tested_check_index) ++
        Enum.map(h.port_errors, & &1.tested_check_index)

    entries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn idx, {:ok, seen} ->
      cond do
        idx >= n_checks ->
          {:halt, {:error, {:check_index, :out_of_range}}}

        not tcp_mode_in_bits?(elem(checks, idx), h.result_mode_bits) ->
          {:halt, {:error, {:check_index, :not_a_named_tcp_check}}}

        MapSet.member?(seen, idx) ->
          {:halt, {:error, {:check_index, :duplicate}}}

        true ->
          {:cont, {:ok, MapSet.put(seen, idx)}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end

  defp tcp_mode_in_bits?(check, rmb) do
    check.mode in @tcp_modes and (mode_bit(check.mode) &&& rmb) != 0
  end

  # A host listing open ports MUST carry a TCP summary whose open_count equals the listed
  # ports EXACTLY. tested >= open is checked separately, in the summary.
  defp open_port_count(h) do
    cond do
      h.open_ports == [] -> :ok
      is_nil(h.tcp) -> {:error, {:summary, :open_ports_without_tcp}}
      h.tcp.open_count != length(h.open_ports) -> {:error, {:summary, :open_count_mismatch}}
      true -> :ok
    end
  end

  # --- borrowed domains -----------------------------------------------------------------

  defp admitted?(mod, key, value) do
    value in Map.fetch!(SemanticValidate.enum_field_policy(), {mod, key})
  end

  defp mode_bit(mode) do
    Map.get(V1.SweepModeBit.mapping(), Map.get(@mode_to_bit, mode), 0)
  end

  defp mode_protocol_consistent?(c) do
    cond do
      c.mode in @icmp_modes -> c.protocol == :TRANSPORT_PROTOCOL_ICMP and c.port == 0
      c.mode in @tcp_modes -> c.protocol == :TRANSPORT_PROTOCOL_TCP and c.port in 1..65_535
      true -> false
    end
  end

  defp uuid?(v), do: PlanValidate.canonical_uuid?(v)
  defp uuidv7?(v), do: PlanValidate.uuidv7?(v)
end
