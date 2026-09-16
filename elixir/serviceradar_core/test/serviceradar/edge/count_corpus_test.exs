defmodule ServiceRadar.Edge.CountCorpusTest do
  @moduledoc """
  Task 1.5-h: the SHARED STRUCTURAL-COUNT CORPUS, this runtime's half.

  THREE BOUND-VECTOR PAIRS, FOUR TYPED ADAPTERS, SEVEN SITES HERE. `MaxManifestPages` has two
  CARRIERS -- plan pages and recovery pages -- which share the literals in
  `count_corpus.txt` and CANNOT share serialized bytes, because a plan page and a manifest
  page are different messages. Each runtime materialises its own typed lists; what crosses the
  boundary is the literals, the site list and the expected verdicts.

  The eighth site, `recovery_spans_single`, is Go-only: this runtime has no signed
  recovery-control boundary to reach `validateSingleManifestPage` through. The manifest records
  it `n/a` with 1.6-d named, and the guard below refuses an unowned `n/a`.

  ## The literals are read, never derived

  Building `over` as `@max_manifest_pages + 1` moves every row with the bound, so a ceiling
  drifting to 128 would keep the corpus green. The constants are asserted AGAINST the manifest.

  ## Every N+1 artifact is resealed, declarations included

  A 1025-page list whose header still declares 1024 is refused by the COUNT RELATION, not the
  ceiling. The adapters reseal digests and set page_count/page_index from the list they built,
  so the relation agrees and the ceiling is the only rule left to refuse it.

  ## A plain N+1 verdict does not prove a RAW gate

  Measured, not argued: with both raw count gates deleted, EVERY verdict row in this module
  stays green and only the two traced witnesses fail. The decoded gate sitting behind each raw
  gate returns the same bounds error, so no verdict can tell the two stages apart. Each raw
  site therefore carries a TRACED WITNESS that the page decoder was never entered, and each
  witness is paired with a valid control proving the decoder trace is live -- without it,
  "the decoder was not entered" is also what an unloaded module or a dead pattern reports.
  """
  # async: false -- the worker traces are scoped, but `trace_pattern/3` installation and
  # removal are NODE-GLOBAL, so a concurrent suite tracing the same MFA would see these calls.
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1
  alias ServiceRadar.Edge.WireDecode

  @fixtures Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  # ---------------------------------------------------------------------------
  # the shared manifest
  # ---------------------------------------------------------------------------

  defp corpus do
    corpus_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [site, carrier, bound, at, over, go, ex, owner] = String.split(line)

      %{
        site: site,
        carrier: carrier,
        bound: bound,
        at: String.to_integer(at),
        over: String.to_integer(over),
        go: go,
        elixir: ex,
        owner: owner
      }
    end)
  end

  defp corpus_path do
    dir =
      [
        @fixtures,
        System.get_env("TEST_SRCDIR") &&
          Path.join([System.get_env("TEST_SRCDIR"), "_main", "proto/edge/v1/testdata"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.dir?/1)

    if !dir, do: flunk("shared fixture directory not found")
    Path.join(dir, "count_corpus.txt")
  end

  defp row(site), do: Enum.find(corpus(), &(&1.site == site)) || flunk("no row for #{site}")

  test "this runtime's exposed limits match the manifest's literals" do
    # THE MANIFEST IS THE ONLY PLACE A NUMBER APPEARS. An earlier form restated 1024/256 in a
    # `want` map here, which is a second inventory to keep in sync -- and one that agrees with
    # itself while disagreeing with the file. The limits are compared against the PARSED rows.
    limits = RecoveryValidate.limits()

    exposed = %{
      "MaxManifestPages" => limits.max_manifest_pages,
      "MaxSpansPerPage" => limits.max_spans_per_page
    }

    for r <- corpus() do
      assert r.over == r.at + 1, "#{r.site}: the pair must be adjacent"

      case Map.fetch(exposed, r.bound) do
        {:ok, value} ->
          assert value == r.at,
                 "#{r.bound} is #{value} in this runtime, the corpus freezes #{r.at}"

        :error ->
          # MaxRangesPerPage has no exposed accessor here; its literal is still pinned by the
          # corpus and exercised by the plan_ranges site.
          assert r.bound == "MaxRangesPerPage",
                 "#{r.site} names bound #{r.bound}, which this runtime neither exposes nor knows"
      end
    end
  end

  test "the inventory matches the manifest on EVERY column, both directions" do
    # A PARTIAL GUARD IS A GREEN LIGHT FOR DRIFT. Checking site names alone leaves the bound
    # and both verdicts free: MaxRangesPerPage and MaxSpansPerPage share the value 256, so
    # swapping them changes no arithmetic and every consumer stays green while the manifest
    # says something false about which ceiling each site enforces.
    inventory = %{
      "plan_raw" => {"plan_pages", "MaxManifestPages", "refuse", "refuse", "-"},
      "plan_decoded" => {"plan_pages", "MaxManifestPages", "refuse", "refuse", "-"},
      "recovery_raw" => {"recovery_pages", "MaxManifestPages", "refuse", "refuse", "-"},
      "recovery_decoded" => {"recovery_pages", "MaxManifestPages", "refuse", "refuse", "-"},
      "tombstone" => {"recovery_pages", "MaxManifestPages", "refuse", "refuse", "-"},
      "plan_ranges" => {"plan_ranges", "MaxRangesPerPage", "refuse", "refuse", "-"},
      "recovery_spans_chain" => {"recovery_spans", "MaxSpansPerPage", "refuse", "refuse", "-"},
      "recovery_spans_single" => {"recovery_spans", "MaxSpansPerPage", "refuse", "n/a", "1.6-d"}
    }

    known = ["refuse", "accept", "n/a"]

    rows = corpus()

    # SET EQUALITY DOES NOT SEE A DUPLICATE. A row pasted twice collapses in the MapSet and
    # every per-row check below passes on it, so the manifest could carry a site twice -- with
    # the second copy silently authoritative for nobody -- and stay green.
    assert length(rows) == map_size(inventory), "the manifest has a duplicate or missing row"
    assert MapSet.new(rows, & &1.site) == MapSet.new(Map.keys(inventory))

    for r <- rows do
      assert {r.carrier, r.bound, r.go, r.elixir, r.owner} == inventory[r.site],
             "#{r.site}: the manifest and the inventory disagree"

      assert r.go in known and r.elixir in known,
             "#{r.site}: verdict tokens #{r.go}/#{r.elixir} are not both recognised"
    end
  end

  test "an absent peer names its owner" do
    for r <- corpus() do
      if r.elixir == "n/a" do
        assert r.owner != "-", "#{r.site}: no Elixir peer and no owner named"
      else
        assert r.owner == "-", "#{r.site}: an owner is named for a site that has a peer"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # adapters
  # ---------------------------------------------------------------------------

  # A manifest page carrying ONE unattributable span. That shape is deliberate: an attributed
  # span carries three UUIDs and three digests, and 1025 of those exceed the manifest BYTE
  # ceiling -- which would then refuse the list before the COUNT ceiling was reached.
  defp manifest_pages(n), do: manifest_pages(n, 1)

  defp manifest_pages(n, spans_per_page) do
    {pages, _} =
      Enum.map_reduce(0..(n - 1), <<>>, fn i, prev ->
        page = %EdgeLossManifestPageV1{
          recovery_id: uuidv7(0x41),
          page_index: i,
          page_count: n,
          prev_page_sha256: prev,
          terminal: i == n - 1,
          digest_version: 1,
          classification_spans: spans(spans_per_page, i)
        }

        sealed = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}
        {sealed, sealed.page_sha256}
      end)

    pages
  end

  defp spans(n, page_index) do
    Enum.map(0..(n - 1), fn i ->
      from = page_index * 100_000 + i * 10 + 1

      %EdgeClassificationSpanV1{
        from_sequence: from,
        through_sequence: from + 1,
        classification:
          {:unattributable,
           %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING}}
      }
    end)
  end

  defp raw_pages(pages) do
    raw = Enum.map(pages, &EdgeLossManifestPageV1.encode/1)
    total = raw |> Enum.map(&byte_size/1) |> Enum.sum()

    # THE BYTE CEILING MUST NOT SHADOW THE COUNT CEILING.
    assert total <= RecoveryValidate.limits().max_manifest_bytes,
           "the #{length(pages)}-page fixture aggregates #{total} bytes, over the " <>
             "manifest byte ceiling; that would refuse the list for SIZE and the row would " <>
             "prove a bound it does not name"

    raw
  end

  # A DISTINCT canonical UUIDv7 per ordinal. `uuidv7/1` seeds every byte the same, so it yields
  # only 256 values -- and the plan validator refuses a DUPLICATE range id, which would refuse
  # the fixture for uniqueness long before any count ceiling was reached.
  defp uuidv7_at(n) do
    <<a::48, _::4, b::12, _::2, c::62>> = <<n::128>>
    <<a::48, 7::4, b::12, 2::2, c::62>>
  end

  defp uuidv7(seed) do
    <<a::48, _::4, b::12, _::2, c::62>> = :binary.copy(<<seed>>, 16)
    <<a::48, 7::4, b::12, 2::2, c::62>>
  end

  # ---------------------------------------------------------------------------
  # per-site consumers
  # ---------------------------------------------------------------------------

  describe "MaxManifestPages, recovery carrier" do
    test "recovery_decoded" do
      r = row("recovery_decoded")

      at = manifest_pages(r.at)
      assert :ok = RecoveryValidate.manifest_chain(at, HashGrammar.manifest_root(at))

      over = manifest_pages(r.over)

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain(over, HashGrammar.manifest_root(over))
    end

    test "recovery_raw" do
      r = row("recovery_raw")

      at = manifest_pages(r.at)

      assert :ok =
               RecoveryValidate.manifest_chain_from_raw(
                 raw_pages(at),
                 HashGrammar.manifest_root(at)
               )

      over = manifest_pages(r.over)

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain_from_raw(
                 raw_pages(over),
                 HashGrammar.manifest_root(over)
               )
    end

    test "tombstone -- the DECLARATION moves with the list" do
      r = row("tombstone")

      at = manifest_pages(r.at)
      assert :ok = RecoveryValidate.tombstone(tombstone_for(at), at)

      # Declaring 1024 over a 1025-page list would be refused by the count RELATION, and the
      # row would pass with the ceiling deleted.
      over = manifest_pages(r.over)
      t = tombstone_for(over)
      assert t.manifest_page_count == r.over

      assert {:error, :manifest_bounds} = RecoveryValidate.tombstone(t, over)
    end
  end

  describe "MaxManifestPages and MaxRangesPerPage, plan carrier" do
    test "plan_decoded" do
      r = row("plan_decoded")

      {h, at} = plan(r.at, 1)
      assert {:ok, _} = PlanValidate.validate(h, at)

      {oh, over} = plan(r.over, 1)
      assert {:error, :page_bounds} = PlanValidate.validate(oh, over)
    end

    test "plan_raw" do
      r = row("plan_raw")

      # THE PUBLIC BOUNDARY ACCEPTS AT N. Anything weaker -- "not a page-bounds refusal" --
      # lets a plan this boundary rejects for another reason still satisfy the row, which is
      # not what the ceiling claims. Each list carries its OWN valid assignment, so the page
      # COUNT is the only INDEPENDENT variable -- the resealed digests, the header's
      # declarations and the assignment's binding fields all follow from it, and holding any
      # of them fixed would make the N+1 artifact self-inconsistent.
      {h, at} = plan(r.at, 1)

      assert {:ok, _} = plan_raw(h, at)

      {oh, over} = plan(r.over, 1)
      assert {:error, :page_bounds} = plan_raw(oh, over)
    end

    test "plan_ranges" do
      r = row("plan_ranges")

      {h, at} = plan(1, r.at)
      assert {:ok, _} = PlanValidate.validate(h, at)

      {oh, over} = plan(1, r.over)
      assert {:error, :page_bounds} = PlanValidate.validate(oh, over)

      # THE PAGE BYTE CEILING IS EXCLUDED BY THE VALIDATOR, NOT BY A COPIED LITERAL. An
      # oversize page returns `:page_bounds` too, so the refusal above proves the count rule
      # only if the size rule had slack over that page -- and `@max_plan_page_bytes` is
      # private, so an assertion against a copied `128 * 1024` would keep passing while the
      # real ceiling was tightened between the two encoded sizes and did all the refusing.
      #
      # This control has N ranges -- ACCEPTED -- and encodes LARGER than the refused N+1 page.
      # Any ceiling low enough to have refused N+1 for size refuses this too, so the row fails
      # rather than quietly changing which rule it proves.
      {fh, fat} = plan(1, r.at, &fat_plan_range/1)

      assert page_bytes(fat) > page_bytes(over),
             "the fat control must encode larger than the refused page, or it bounds nothing"

      assert {:ok, _} = PlanValidate.validate(fh, fat)
    end
  end

  describe "MaxSpansPerPage, recovery carrier" do
    test "recovery_spans_chain" do
      r = row("recovery_spans_chain")

      at = manifest_pages(1, r.at)
      assert :ok = RecoveryValidate.manifest_chain(at, HashGrammar.manifest_root(at))

      over = manifest_pages(1, r.over)

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain(over, HashGrammar.manifest_root(over))
    end

    test "recovery_spans_single is GO-ONLY, and the manifest says so" do
      # This runtime has no signed recovery-control boundary, so there is nothing to drive the
      # single-page ceiling through. Recorded, not silently skipped.
      r = row("recovery_spans_single")

      assert r.elixir == "n/a"
      assert r.owner == "1.6-d"
    end
  end

  # A VALID n-page plan with `per_page` ranges each. Every digest is resealed and the header's
  # declarations -- page_count, total_target_count, plan root, MTR commitment -- are computed
  # from the pages actually built, so the N+1 case is refused by the CEILING and not by a
  # declaration that disagrees with the list.
  defp plan(n, per_page, range_fun \\ &plan_range/1) do
    {pages, _} =
      Enum.map_reduce(0..(n - 1), <<>>, fn i, prev ->
        # A GLOBAL index, so every address is distinct AND every octet stays in range.
        # `page_index * 100_000 + i` overflowed the third octet past page 42 and produced
        # "10.1560.x.y", which is not an address at all.
        ranges = Enum.map(0..(per_page - 1), &range_fun.(i * per_page + &1))

        page = %{
          template_page()
          | page_index: i,
            page_count: n,
            prev_page_sha256: prev,
            ranges: ranges
        }

        sealed = %{page | page_sha256: HashGrammar.plan_page_digest(page)}
        {sealed, sealed.page_sha256}
      end)

    {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment(pages)

    h = %{
      template_header()
      | page_count: n,
        plan_root_sha256: HashGrammar.plan_root(pages),
        total_target_count: n * per_page,
        mtr_ordinal_range_commitment: commitment
    }

    {%{h | execution_plan_sha256: HashGrammar.plan_header_digest(h)}, pages}
  end

  # THE SAME RANGE, DELIBERATELY FAT. Canonical full-length IPv6 is 39 bytes against an IPv4
  # `10.x.y.z`'s 8-11, so 256 of these encode LARGER than the 257-range IPv4 page. Every group
  # is non-zero, so `:inet.ntoa/1` cannot compress it and the spelling is canonical -- an
  # expanded form like `2001:0db8:...:0001` would be refused for spelling, not admitted as
  # padding. first == last keeps the span 1, so `total_target_count` still reconciles.
  defp fat_plan_range(n) do
    a = "aaaa:bbbb:cccc:dddd:eeee:ffff:" <> hex4(div(n, 65_536)) <> ":" <> hex4(rem(n, 65_536))
    r = %{plan_range(n) | first_address: a, last_address: a}
    %{r | range_sha256: HashGrammar.range_digest(r)}
  end

  # NO ZERO GROUP: a zero would let `::` compress the address and the spelling would stop being
  # canonical, so the low 16 bits are folded into 0x1000..0xffff.
  defp hex4(v) do
    (0x1000 + rem(v, 0xF000))
    |> Integer.to_string(16)
    |> String.downcase()
  end

  defp plan_range(n) do
    r = %{
      template_range()
      | range_id: uuidv7_at(n),
        cidr: "",
        # ZERO MTR, stated explicitly. The template range admits 2 ordinals, and 1024 pages of
        # those exceed the plan WORK ceiling -- the commitment fold would refuse the fixture
        # before any count ceiling was reached, so that bound would shadow this one.
        mtr_ordinal_count: 0,
        mtr_admission_budget: 0,
        first_address:
          "10." <>
            Integer.to_string(div(n, 65_536)) <>
            "." <>
            Integer.to_string(rem(div(n, 256), 256)) <> "." <> Integer.to_string(rem(n, 256)),
        last_address:
          "10." <>
            Integer.to_string(div(n, 65_536)) <>
            "." <>
            Integer.to_string(rem(div(n, 256), 256)) <> "." <> Integer.to_string(rem(n, 256)),
        target_count: 1
    }

    %{r | range_sha256: HashGrammar.range_digest(r)}
  end

  # A VALID assignment BOUND TO THE GENERATED PLAN. `validate_bytes_against_plan_bytes/3`
  # validates the record and its plan relation after the count gate, so an empty record would
  # force the at-ceiling row to assert "not a page-bounds refusal" -- another rule's outcome
  # standing in for this one's.
  #
  # A SITE ADAPTER, NOT ANOTHER VECTOR PAIR: the same generated plan is reused and only the
  # fields that BIND a record to it are re-pointed. The page COUNT is the only INDEPENDENT
  # variable between the two rows; the digests and binding fields necessarily move with it,
  # because an N+1 artifact that kept N's digests would be refused by a relation instead.
  defp assignment_for(header, pages) do
    range = hd(hd(pages).ranges)

    base = "assignment_zero_mtr.bin" |> fixture() |> SweepAssignmentRecordV1.decode()

    %{
      base
      | execution_plan_id: header.execution_plan_id,
        execution_plan_sha256: header.execution_plan_sha256,
        # RE-POINTED, not inherited: the two fixtures happen to carry the same scope, so
        # omitting this passed for a reason the adapter does not control.
        network_scope_id: header.network_scope_id,
        target_range_id: range.range_id,
        target_range_sha256: range.range_sha256,
        availability_policy_id: header.availability_policy_id,
        check_set_sha256: header.check_set_sha256
    }
  end

  defp plan_raw(header, pages) do
    raw = Enum.map(pages, &ScheduledPlanPageV1.encode/1)
    header_bytes = ScheduledPlanHeaderV1.encode(header)
    record = SweepAssignmentRecordV1.encode(assignment_for(header, pages))

    AssignmentValidate.validate_bytes_against_plan_bytes(record, header_bytes, raw)
  end

  defp template_page, do: "plan_page.bin" |> fixture() |> ScheduledPlanPageV1.decode()

  defp template_header, do: "plan_header.bin" |> fixture() |> ScheduledPlanHeaderV1.decode()

  defp template_range, do: hd(template_page().ranges)

  defp page_bytes(pages),
    do: pages |> Enum.map(&byte_size(ScheduledPlanPageV1.encode(&1))) |> Enum.sum()

  defp fixture(name), do: corpus_path() |> Path.dirname() |> Path.join(name) |> File.read!()

  # THE GENERATED STRUCT, NOT A SHAPE-COMPATIBLE MAP. `tombstone/2` reads `t` by field and
  # never type-checks it, so NO VERDICT SEPARATES THE TWO -- the map this replaced passed. That
  # is precisely why it had to change: the row would have proved the ceiling over an input the
  # wire cannot produce, and the equivalence holds only until a field is added to the message,
  # at which point the map silently keeps whatever default the test author last wrote. The
  # struct also drops the hand-maintained `__unknown_fields__: []`, which existed only to
  # satisfy `no_unknown_fields?/1`.
  defp tombstone_for(pages) do
    %SpoolLossTombstoneV1{
      recovery_id: hd(pages).recovery_id,
      prior_spool_id: uuidv7(0x11),
      new_spool_id: uuidv7(0x22),
      detected_at_unix_nano: 1_700_000_000_000_000_000,
      digest_version: 1,
      manifest_page_count: length(pages),
      manifest_root_sha256: HashGrammar.manifest_root(pages),
      reason: "corpus"
    }
  end

  # ---------------------------------------------------------------------------
  # RAW-SITE STAGE WITNESS
  # ---------------------------------------------------------------------------

  describe "the raw gates run BEFORE decoding" do
    # A PLAIN N+1 VERDICT DOES NOT PROVE A RAW GATE: remove it and the decoded gate returns the
    # same bounds error. Only a trace shows the decoder was never entered.

    setup do
      {:module, _} = Code.ensure_loaded(WireDecode)

      decoder = {WireDecode, :decode_manifest_page, 1}

      assert :erlang.trace_pattern(decoder, true, [:local]) >= 1,
             "the decoder trace pattern matched nothing"

      on_exit(fn -> :erlang.trace_pattern(decoder, false, [:local]) end)

      %{decoder: decoder}
    end

    test "a VALID raw manifest DOES reach the decoder -- the live-trace control", ctx do
      r = row("recovery_raw")
      at = manifest_pages(r.at)

      calls =
        traced(fn ->
          RecoveryValidate.manifest_chain_from_raw(raw_pages(at), HashGrammar.manifest_root(at))
        end)

      assert ctx.decoder in calls,
             "the decoder trace is not live; the row below would report 'not decoded' for " <>
               "that reason instead of the one it names"
    end

    test "an OVER-COUNT raw manifest never reaches the decoder", ctx do
      r = row("recovery_raw")
      over = manifest_pages(r.over)

      calls =
        traced(fn ->
          RecoveryValidate.manifest_chain_from_raw(
            raw_pages(over),
            HashGrammar.manifest_root(over)
          )
        end)

      refute ctx.decoder in calls,
             "the raw count gate did not run before decoding: an over-count list was decoded " <>
               "page by page, which is the work the ceiling exists to prevent"
    end
  end

  describe "the RAW PLAN gate runs before decoding" do
    setup do
      {:module, _} = Code.ensure_loaded(WireDecode)

      decoder = {WireDecode, :decode_plan_page, 1}

      assert :erlang.trace_pattern(decoder, true, [:local]) >= 1,
             "the plan-page decoder trace pattern matched nothing"

      on_exit(fn -> :erlang.trace_pattern(decoder, false, [:local]) end)

      %{decoder: decoder}
    end

    test "a VALID raw plan DOES reach the decoder -- the live-trace control", ctx do
      r = row("plan_raw")
      {h, at} = plan(r.at, 1)

      assert ctx.decoder in traced(fn -> plan_raw(h, at) end),
             "the plan-page decoder trace is not live; the row below would report " <>
               "'not decoded' for that reason instead of the one it names"
    end

    test "an OVER-COUNT raw plan never reaches the decoder", ctx do
      r = row("plan_raw")
      {oh, over} = plan(r.over, 1)

      refute ctx.decoder in traced(fn -> plan_raw(oh, over) end),
             "the raw count gate did not run before decoding: an over-count page list was " <>
               "decoded page by page, which is the work the ceiling exists to prevent"
    end
  end

  defp traced(fun) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        _ = fun.()
        send(test, {:done, self()})
      end)

    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    receive do
      {:done, ^pid} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> flunk("worker died: #{inspect(reason)}")
    after
      30_000 -> flunk("worker did not finish")
    end

    delivery = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^delivery} -> :ok
    after
      30_000 -> flunk("trace delivery did not complete")
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> drain([{m, f, length(args)} | acc])
      {:DOWN, _, :process, _, _} -> drain(acc)
    after
      0 -> Enum.uniq(acc)
    end
  end
end
