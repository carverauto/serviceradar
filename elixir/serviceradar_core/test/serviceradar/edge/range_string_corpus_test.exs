defmodule ServiceRadar.Edge.RangeStringCorpusTest do
  @moduledoc """
  Task 1.5-h: PLAN RANGE ADDRESS STRINGS -- the IPv6-zone prohibition, and the guard bound that
  prohibition puts back out of reach. Peer of Go's `range_string_corpus_test.go`.

  ## Three parts, and only the first is a semantic rule

    1. ZONE-PRESENT REFUSAL -- the only rows whose verdict changes if the prohibition is dropped.
    2. ACCEPTED CONTROLS at the largest valid syntax, per field. Without them an
       always-refusing validator satisfies part 3.
    3. ONE OVER-LIMIT, PARSER-NOT-ENTERED control per field.

  There is no WHOLE-VALIDATOR at-ceiling/one-over pair: once zones are forbidden no canonical
  address reaches `MaxRangeStrBytes`, so an input accepted at the ceiling by the whole
  validator does not exist to construct. The SEAM has such a pair, and that is where the
  frozen literal is pinned.

  ## WHERE EACH ROW PROVES SOMETHING, and where it only pins a verdict

  THE SEAM ROWS ARE MUTATION-KILLING: drifting the bound or tightening `>` to `>=` fails them,
  and so does dropping or narrowing the zone check. They are also the only place the frozen
  ceiling can be pinned here, since no canonical address reaches it.

  THE VALIDATOR-LEVEL ROWS ARE REGRESSION PINS ONLY, and that is a property of this runtime
  rather than a gap in the corpus. Everything the preflight refuses is ALSO refused downstream
  -- zones by the canonical-spelling check, over-length values by the parser -- so removing the
  preflight entirely, or replacing its call with a forged checked value, changes NO verdict.
  Measured across zoned spans, zoned CIDRs, over-length values in each field, and valid
  controls: every candidate is identical either way.

  THE ATTACHMENT IS PROVEN ELSEWHERE, by observing the STAGE rather than the verdict:
  `range_string_stage_test.exs` traces the preflight and `:inet.parse_strict_address/1` through
  the real validator, so a forged handoff fails there. No verdict row here can do that, and
  none pretends to.

  The reason is that this runtime already refuses a zoned address, by a different rule at a
  later stage. `:inet.parse_strict_address/1` ACCEPTS the zoned text and silently DISCARDS the
  zone, so `canonical_addr?/2` then compares `:inet.ntoa/1`'s output against the input and
  refuses the mismatch as a non-canonical SPELLING. No zoned value can round-trip, so the
  spelling rule catches every one -- and it reports `:plan_range`, the SAME atom the zone gate
  returns. A verdict assertion cannot separate them.

  The gate is still correct and still required: the frozen rule says a zone is refused BEFORE
  either parser, and the spelling rule runs after. THE STAGE IS OBSERVED AT THE VALIDATOR --
  `range_string_stage_test.exs` traces the preflight and `:inet.parse_strict_address/1` through
  the real `PlanValidate.validate/2` -- so no distinct refusal reason was ever needed. What no
  row in THIS file can do is separate the two by verdict.

  So these are REGRESSION rows: they pin the current verdict per field, and they would catch a
  change that made this runtime ADMIT a zoned address. They do not claim to prove the gate.
  Go's peer suite is where the gate is load-bearing and mutation-killed -- `netip` accepts a
  scoped address and round-trips it canonically, so without the gate Go ADMITS what this
  runtime refuses.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate

  @fixtures Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  describe "the preflight seam" do
    # THE SEAM IS ADDRESSED DIRECTLY. `__check_range_strings__/3` parses nothing, so a row
    # against it constrains the ORDER -- an input refused there never reached a parser.
    # It is also the ONLY place the frozen ceiling can be pinned in this runtime: no canonical
    # address reaches 64 bytes, and a 65-byte refusal driven through `validate/2` survives the
    # bound drifting anywhere from 43 to 65, because the address parser refuses those lengths
    # regardless.

    test "the frozen literal 64 is pinned, and 65 is refused" do
      for field <- [:cidr, :first, :last] do
        assert {:ok, _} = with_field(field, String.duplicate("z", 64)),
               "exactly 64 bytes must pass the preflight for #{field}"

        assert {:error, :plan_range} = with_field(field, String.duplicate("z", 65)),
               "65 bytes must be refused for #{field}, before any parser"
      end
    end

    test "each field refuses a zone INDEPENDENTLY" do
      # A prohibition applied to `cidr` alone would leave a zoned span admitted.
      for field <- [:cidr, :first, :last] do
        assert {:error, :plan_range} = with_field(field, "fe80::1%eth0"),
               "a zoned #{field} must be refused"

        # The SAME value without its zone passes, so the refusal is attributable to the zone.
        assert {:ok, _} = with_field(field, "fe80::1")
      end
    end
  end

  describe "whole-validator acceptance" do
    test "the longest canonical CIDR is accepted" do
      # Without an accepted control an always-refusing implementation satisfies every refusal
      # row above, and the preflight would look proven while the range path admitted nothing.
      r = %{
        range()
        | cidr: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:8000/113",
          first_address: "",
          last_address: ""
      }

      assert :ok = validate_range(%{r | target_count: 32_768})
    end

    test "the longest canonical address span is accepted" do
      addr = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
      r = %{range() | cidr: "", first_address: addr, last_address: addr}

      assert :ok = validate_range(%{r | target_count: 1})
    end

    test "a zoned address does not reach acceptance, and the reason stays :plan_range" do
      # A REGRESSION row for the VERDICT -- this runtime already refused zoned addresses
      # through its spelling check, so removing the gate does not change it. What it would
      # catch is a change that made this runtime ADMIT one.
      #
      # It also pins the REASON as the existing `:plan_range`. A fault-specific tag here
      # would be this subtask quietly minting a refusal class that 1.5-l owns.
      zoned = %{range() | cidr: "", first_address: "fe80::1%eth0", last_address: "fe80::1%eth0"}
      over = %{range() | cidr: String.duplicate("z", 65), first_address: "", last_address: ""}

      assert {:error, :plan_range} = validate_range(%{zoned | target_count: 1})
      assert {:error, :plan_range} = validate_range(%{over | target_count: 1})
    end
  end

  defp with_field(:cidr, v), do: PlanValidate.__check_range_strings__(v, "", "")
  defp with_field(:first, v), do: PlanValidate.__check_range_strings__("", v, "")
  defp with_field(:last, v), do: PlanValidate.__check_range_strings__("", "", v)

  # Drives the REAL page validator, resealing the range digest so a refusal is attributable to
  # the rule under test rather than to a stale digest.
  defp validate_range(r) do
    sealed = %{r | range_sha256: HashGrammar.range_digest(r)}
    page = %{page() | ranges: [sealed]}
    resealed = %{page | page_sha256: HashGrammar.plan_page_digest(page)}

    header = header_for(resealed)

    case PlanValidate.validate(header, [resealed]) do
      {:ok, _windows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp header_for(page) do
    # The MTR ordinal-range commitment is folded over the ranges, so changing a range without
    # recomputing it makes every row fail on the commitment instead of the rule under test.
    {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment([page])

    h = %{
      header()
      | page_count: 1,
        plan_root_sha256: HashGrammar.plan_root([page]),
        total_target_count: hd(page.ranges).target_count,
        mtr_ordinal_range_commitment: commitment
    }

    %{h | execution_plan_sha256: HashGrammar.plan_header_digest(h)}
  end

  defp range, do: hd(page().ranges)

  defp page, do: "plan_page.bin" |> load() |> Serviceradar.Edge.V1.ScheduledPlanPageV1.decode()

  defp header,
    do: "plan_header.bin" |> load() |> Serviceradar.Edge.V1.ScheduledPlanHeaderV1.decode()

  defp load(name) do
    dir =
      [
        @fixtures,
        System.get_env("TEST_SRCDIR") &&
          Path.join([System.get_env("TEST_SRCDIR"), "_main", "proto/edge/v1/testdata"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.dir?/1)

    if !dir, do: flunk("shared fixture directory not found")
    File.read!(Path.join(dir, name))
  end
end
