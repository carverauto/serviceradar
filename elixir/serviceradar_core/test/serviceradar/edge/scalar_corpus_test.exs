defmodule ServiceRadar.Edge.ScalarCorpusTest do
  @moduledoc """
  Task 1.5-h: the SHARED SCALAR / CARRIER CORPUS, this runtime's half.

  FIVE BOUNDS, EIGHT SITES, FIVE OF THE SITES HERE. `MaxPolicyIDBytes` and `MaxPrincipalBytes`
  are both 128 and stay SEPARATE NAMED bounds: they bound different quantities and either may
  move alone, so collapsing them would hide one bound's drift behind the other's rows.

  The abort reason and signed tombstone reason retain explicit owners for their
  absent peers; the raw record boundary now covers the producer-context principal.

  ## A lower bound needs two controls, not one

  SEVEN of the eight sites are SEMANTICALLY two-sided -- they admit 1..Max, whatever spelling
  the gate uses -- so each freezes a MINIMUM OF 1 as well as a ceiling. A zero-refusal alone
  does not pin it: a guard tightened to reject length 1 refuses zero exactly as before. Each of
  those sites carries FOUR controls: 0 refused, 1 ACCEPTED, at accepted, over refused.

  They are needed AT EACH SITE, not once per helper: both principal slots funnel into
  `valid_authenticated_principal?/1`, so a helper-level row proves the HELPER's arithmetic, not
  that a given slot still routes through it.

  `plan_header_raw` is ONE-SIDED. Its `zero` and `min` columns are both `n/a` and it carries
  at/over plus a STAGE WITNESS instead: an at/over pair cannot show that a RAW ceiling runs
  before the decode.

  ## The literals are read, never derived

  Building `over` as `@max_... + 1` moves every row with the bound, so a ceiling drifting to 64
  would keep the corpus green. Every ceiling this runtime applies here is PRIVATE, and none is
  exposed for the test's benefit -- an accessor that exists for a test is API the test invented.
  The values are pinned BEHAVIOURALLY instead: accepting exactly `at` and refusing exactly
  `over` at the production boundary is the pin.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Edge.WireValidate

  @corpus "scalar_corpus.txt"

  describe "the manifest and this runtime agree" do
    test "the inventory matches the manifest on EVERY column, both directions" do
      # A PARTIAL GUARD IS A GREEN LIGHT FOR DRIFT. Site names alone leave the bound and the
      # verdicts free -- and MaxPolicyIDBytes and MaxPrincipalBytes are both 128, so swapping
      # them changes no arithmetic while the manifest says something false about which ceiling
      # each site enforces.
      inventory = %{
        "policy_plan_header" => {"MaxPolicyIDBytes", "refuse", 1, "refuse", "refuse", "-"},
        "policy_assignment_record" => {"MaxPolicyIDBytes", "refuse", 1, "refuse", "refuse", "-"},
        "principal_producer_context" =>
          {"MaxPrincipalBytes", "refuse", 1, "refuse", "refuse", "-"},
        "principal_edge_slot" => {"MaxPrincipalBytes", "refuse", 1, "refuse", "refuse", "-"},
        "principal_service_slot" => {"MaxPrincipalBytes", "refuse", 1, "refuse", "refuse", "-"},
        "plan_header_raw" => {"MaxPlanHeaderBytes", "n/a", nil, "refuse", "refuse", "-"},
        "abort_reason" => {"MaxTraceStrBytes", "refuse", 1, "refuse", "n/a", "1.6-c"},
        "tombstone_reason_signed" => {"MaxReasonBytes", "refuse", 1, "refuse", "n/a", "1.6-d"}
      }

      known = ["refuse", "accept", "n/a"]
      rows = corpus()

      # THE DISTINCT BOUND SET, not a count. A count alone admits a row retitled under an
      # existing bound; the set alone admits a duplicate. Both are checked.
      assert MapSet.new(rows, & &1.bound) ==
               MapSet.new([
                 "MaxPolicyIDBytes",
                 "MaxPrincipalBytes",
                 "MaxPlanHeaderBytes",
                 "MaxTraceStrBytes",
                 "MaxReasonBytes"
               ])

      # SET EQUALITY DOES NOT SEE A DUPLICATE: a row pasted twice collapses in the MapSet and
      # every per-row check below then passes on it.
      assert length(rows) == map_size(inventory), "the manifest has a duplicate or missing row"
      assert MapSet.new(rows, & &1.site) == MapSet.new(Map.keys(inventory))

      for r <- rows do
        assert {r.bound, r.zero, r.min, r.go, r.elixir, r.owner} == inventory[r.site],
               "#{r.site}: the manifest and the inventory disagree"

        assert r.zero in known and r.go in known and r.elixir in known,
               "#{r.site}: verdict tokens #{r.zero}/#{r.go}/#{r.elixir} are not all recognised"

        assert r.over == r.at + 1, "#{r.site}: the pair must be adjacent"

        # A TWO-SIDED SITE MUST NAME ITS MINIMUM, and a one-sided one must not: a `zero:
        # refuse` row with no `min` looks complete while leaving the frozen minimum free to
        # move up.
        assert r.min != nil == (r.zero != "n/a"),
               "#{r.site}: zero=#{r.zero} but min=#{inspect(r.min)}"

        if r.min, do: assert(r.min >= 1 and r.min <= r.at, "#{r.site}: min out of range")
      end
    end

    test "an absent peer names its owner" do
      for r <- corpus() do
        if r.elixir == "n/a" do
          assert r.owner != "-", "#{r.site}: no peer here and no owner named"
        else
          assert r.owner == "-", "#{r.site}: an owner is named for a site that has a peer"
        end
      end
    end
  end

  describe "MaxPolicyIDBytes -- two carriers" do
    test "policy_plan_header" do
      r = row("policy_plan_header")

      assert {:ok, _} = policy_plan(r.at)

      # CONSISTENT over-limit -- the same value in the header AND in every range, so only the
      # header's LENGTH rule can refuse it. An inconsistent fixture would be refused by the
      # range's EQUALITY arm, proving a different rule under a verdict that looks right. The
      # length bound lives at the header alone.
      assert {:error, :header_identity} = policy_plan(r.over)
      assert {:error, :header_identity} = policy_plan(0)

      # THE FROZEN MINIMUM IS ACCEPTED. Without it the gate could be tightened to reject
      # length 1 and every row above would still pass.
      assert {:ok, _} = policy_plan(r.min)
    end

    test "policy_assignment_record" do
      r = row("policy_assignment_record")

      assert :ok = policy_assignment(r.at)
      assert {:error, :scope} = policy_assignment(r.over)

      # THE SECOND CARRIER'S LOWER BOUND IS ITS OWN RULE. The two carriers share one logical
      # vector but not one gate: deleting either leaves the other's rows green.
      assert {:error, :scope} = policy_assignment(0)
      assert :ok = policy_assignment(r.min)
    end
  end

  describe "MaxPrincipalBytes -- both publication slots and the record" do
    test "principal_producer_context" do
      r = row("principal_producer_context")

      for {n, accepted} <- [{0, false}, {r.min, true}, {r.at, true}, {r.over, false}] do
        raw =
          File.read!(
            Path.expand(
              "../../../../../proto/edge/v1/testdata/record_boundary_principal_#{n}.bin",
              __DIR__
            )
          )

        result = ServiceRadar.Edge.RecordValidate.validate_bytes(raw)

        if accepted,
          do: assert(match?({:ok, _}, result)),
          else: assert(result == {:error, :principal})
      end
    end

    test "principal_edge_slot" do
      r = row("principal_edge_slot")

      slot = fn id ->
        %{
          network_scope_id: uuidv7(0x31),
          authenticated_agent_id: id,
          spool_id: uuidv7(0x32),
          sequence: 1
        }
      end

      assert {:ok, _} = PublicationIdentity.delivery_id_preimage(slot.(ascii(r.at)))
      assert {:error, _} = PublicationIdentity.delivery_id_preimage(slot.(ascii(r.over)))

      # THE LOWER BOUND IS TWO CONTROLS, both AT THIS SITE. Zero refused alone leaves the
      # frozen minimum free to move up -- a guard tightened to reject length 1 refuses zero
      # exactly as before -- so the smallest admissible value must be ACCEPTED too. And a
      # helper-level row proves the helper refuses zero, not that this slot still calls it.
      assert {:error, _} = PublicationIdentity.delivery_id_preimage(slot.(<<>>))
      assert {:ok, _} = PublicationIdentity.delivery_id_preimage(slot.(ascii(r.min)))
    end

    test "principal_service_slot" do
      r = row("principal_service_slot")

      slot = fn id ->
        %{
          network_scope_id: uuidv7(0x41),
          authenticated_service_id: id,
          publication_lane_id: uuidv7(0x42),
          publication_sequence: 1
        }
      end

      assert {:ok, _} = PublicationIdentity.service_delivery_id_preimage(slot.(ascii(r.at)))
      assert {:error, _} = PublicationIdentity.service_delivery_id_preimage(slot.(ascii(r.over)))
      assert {:error, _} = PublicationIdentity.service_delivery_id_preimage(slot.(<<>>))
      assert {:ok, _} = PublicationIdentity.service_delivery_id_preimage(slot.(ascii(r.min)))
    end
  end

  describe "MaxPlanHeaderBytes -- the one RAW, one-sided site" do
    test "plan_header_raw" do
      r = row("plan_header_raw")

      # ONE-SIDED, and the manifest says so on BOTH columns: no zero rule and no frozen
      # minimum. An empty header is refused for being an incomplete header, not by this
      # ceiling, which only bounds from above.
      assert r.zero == "n/a"
      assert r.min == nil

      assert {:ok, _} = WireDecode.decode_plan_header(padded_header(r.at))
      assert {:error, :too_large} = WireDecode.decode_plan_header(padded_header(r.over))
    end

    test "the padded encodings are VALID, not merely long" do
      r = row("plan_header_raw")
      {h, _} = plan()

      # A fixture that only reached the ceiling by being malformed would be refused by the
      # DECODER, and the row above would prove nothing about the ceiling. Both encodings must
      # decode to the SAME header the padding started from.
      assert {:ok, decoded} = WireDecode.decode_plan_header(padded_header(r.at))
      assert decoded == h

      assert byte_size(padded_header(r.at)) == r.at
      assert byte_size(padded_header(r.over)) == r.over
      assert ScheduledPlanHeaderV1.decode(padded_header(r.over)) == h
    end

    test "the size gate runs BEFORE the decode" do
      r = row("plan_header_raw")

      # THE STAGE, which the N/N+1 pair cannot prove: a boundary that decoded first and bounded
      # afterwards returns the same verdict on the same inputs. This witness is over-limit AND
      # undecodable, and the two stages have DIFFERENT verdicts -- `:too_large` for the size
      # gate, `:poison` for a structural failure -- so the order is observable without tracing.
      #
      # A length-delimited field declaring more bytes than remain: truncation, which every
      # parser must reject.
      tag = <<field_number(:check_set_sha256) <<< 3 ||| 2>>
      witness = padded_header(r.over) <> tag <> varint(64)

      # THE WITNESS ITSELF MUST BE UNDECODABLE -- asserted on THESE EXACT BYTES, through both
      # the structural gate and the generated decoder. Checking a truncated PREFIX instead
      # would prove some other input is poison while leaving the witness possibly decodable, in
      # which case `:too_large` below could be the only verdict it was ever going to get and
      # the ordering claim would rest on nothing.
      assert {:error, :poison} = WireValidate.validate(witness, ScheduledPlanHeaderV1)

      assert_raise Protobuf.DecodeError, fn -> ScheduledPlanHeaderV1.decode(witness) end

      assert byte_size(witness) > r.over, "the witness must still be over the ceiling"

      assert {:error, :too_large} = WireDecode.decode_plan_header(witness)
    end
  end

  # ---------------------------------------------------------------------------
  # adapters
  # ---------------------------------------------------------------------------

  defp ascii(n), do: :binary.copy("x", n)

  # A plan whose availability policy is `n` bytes in the HEADER AND IN EVERY RANGE, with every
  # commitment that covers it resealed: range digest, page digest, plan root, MTR commitment,
  # header digest. Holding any of them fixed would make the artifact fail a RELATION rather
  # than the ceiling, so the row would pass while proving the wrong rule.
  defp policy_plan(n) do
    {h0, p0} = plan()
    policy = ascii(n)

    ranges =
      Enum.map(p0.ranges, fn rg ->
        rg = %{rg | availability_policy_id: policy}
        %{rg | range_sha256: HashGrammar.range_digest(rg)}
      end)

    page = %{p0 | page_index: 0, page_count: 1, prev_page_sha256: <<>>, ranges: ranges}
    page = %{page | page_sha256: HashGrammar.plan_page_digest(page)}
    {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment([page])

    h = %{
      h0
      | page_count: 1,
        availability_policy_id: policy,
        plan_root_sha256: HashGrammar.plan_root([page]),
        total_target_count: Enum.sum(Enum.map(ranges, & &1.target_count)),
        mtr_ordinal_range_commitment: commitment
    }

    PlanValidate.validate(%{h | execution_plan_sha256: HashGrammar.plan_header_digest(h)}, [page])
  end

  defp policy_assignment(n) do
    base = "assignment_zero_mtr.bin" |> fixture() |> SweepAssignmentRecordV1.decode()

    %{base | availability_policy_id: ascii(n)}
    |> AssignmentValidate.validate()
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  # A header encoding of EXACTLY `target` bytes that still decodes to the same header. The
  # filler is a DUPLICATE `check_set_sha256` field the true value overwrites -- last wins for a
  # proto3 scalar -- so the padding is inert rather than a malformation.
  defp padded_header(target) do
    {h, _} = plan()
    base = ScheduledPlanHeaderV1.encode(h)
    tag = <<field_number(:check_set_sha256) <<< 3 ||| 2>>
    true_field = tag <> varint(byte_size(h.check_set_sha256)) <> h.check_set_sha256

    filler_total = target - byte_size(base) - byte_size(true_field)
    # tag(1) + length varint + payload
    payload = filler_total - 1 - varint_size(filler_total)
    assert payload >= 0, "target #{target} is too small to pad to"

    base <> tag <> varint(payload) <> :binary.copy(<<0>>, payload) <> true_field
  end

  # READ FROM THE DESCRIPTOR, never hardcoded. A literal tag byte silently targets whichever
  # field holds that number today, which for a padding fixture means padding the wrong field
  # with the wrong wire type and being refused by the decoder rather than reaching the ceiling.
  defp field_number(name) do
    {n, _} =
      Enum.find(ScheduledPlanHeaderV1.__message_props__().field_props, fn {_, p} ->
        p.name_atom == name
      end)

    n
  end

  defp varint(v) when v < 0x80, do: <<v>>
  defp varint(v), do: <<0x80 ||| (v &&& 0x7F)>> <> varint(v >>> 7)

  defp varint_size(v) when v < 0x80, do: 1
  defp varint_size(v), do: 1 + varint_size(v >>> 7)

  defp plan do
    h = "plan_header.bin" |> fixture() |> ScheduledPlanHeaderV1.decode()
    p = "plan_page.bin" |> fixture() |> ScheduledPlanPageV1.decode()
    {h, p}
  end

  defp uuidv7(seed) do
    <<a::48, _::4, b::12, _::2, c::62>> = :binary.copy(<<seed>>, 16)
    <<a::48, 7::4, b::12, 2::2, c::62>>
  end

  # ---------------------------------------------------------------------------
  # manifest
  # ---------------------------------------------------------------------------

  defp row(site) do
    Enum.find(corpus(), &(&1.site == site)) ||
      flunk("no scalar corpus row for site #{site}")
  end

  defp corpus do
    corpus_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(fn line ->
      case String.split(String.trim(line), ~r/\s+/) do
        [site, bound, zero, min, at, over, go, elixir, owner] ->
          %{
            site: site,
            bound: bound,
            zero: zero,
            min: if(min == "n/a", do: nil, else: String.to_integer(min)),
            at: String.to_integer(at),
            over: String.to_integer(over),
            go: go,
            elixir: elixir,
            owner: owner
          }

        other ->
          flunk("scalar corpus row #{inspect(other)} does not have 9 fields")
      end
    end)
  end

  defp corpus_path, do: Path.expand("../../../../../proto/edge/v1/testdata/#{@corpus}", __DIR__)

  defp fixture(name), do: corpus_path() |> Path.dirname() |> Path.join(name) |> File.read!()
end
