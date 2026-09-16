defmodule ServiceRadar.Edge.LowerBoundCorpusTest do
  @moduledoc """
  Task 1.5-h: the SHARED LOWER-BOUND CORPUS, this runtime's half.

  ITS OWN INVENTORY, NOT AN EXTENSION OF THE COUNT CORPUS. The upper table proves each site's
  ceiling with an N/N+1 pair; extending it mechanically with one empty row per site would
  assert independent proofs the implementations do not provide, because several local emptiness
  predicates are SHADOWED by a later check that refuses the same input.

  This file asks a different question and answers it per runtime: what does the BOUNDARY do
  with an empty collection, and what would removing the LOCAL arm actually change? The second
  answer is the `ex_removal` column, and it is MEASURED. See the manifest for what each token
  licenses a row to claim; two matter here:

    * `combined` -- this runtime has NO separable zero arm at that site. The raw plan gate is a
      single conjunction over the declared count, the ceiling and the supplied length, so there
      is nothing to remove independently and the row claims nothing about it.
    * `silent` -- the boundary still refuses under the SAME reason because a later gate catches
      it, so no verdict-based row can kill the removal. The row records boundary behaviour.

  TWO CONTROLS PER RULE. Zero refused alone does not pin a minimum of 1: an implementation
  demanding two elements refuses zero exactly as before. The ONE-element acceptance is what
  makes it a bound rather than a prohibition.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1

  describe "the manifest and this runtime agree" do
    test "the inventory matches the manifest on EVERY column, both directions" do
      # EVERY COLUMN, both runtimes' removal classes included. Omitting `go_removal` would let
      # the other runtime's measured claim drift with nothing here noticing, and omitting
      # at/over would let the declared-scalar ceiling move silently.
      inventory = %{
        "plan_pages_decoded" => {"collection", "retags", "retags", "n/a", "n/a", "-"},
        "plan_pages_raw" => {"collection", "silent", "combined", "n/a", "n/a", "-"},
        "plan_ranges" => {"collection", "admits", "admits", "n/a", "n/a", "-"},
        "recovery_pages_decoded" => {"collection", "crashes", "crashes", "n/a", "n/a", "-"},
        "recovery_pages_raw" => {"collection", "silent", "silent", "n/a", "n/a", "-"},
        "recovery_spans_chain" => {"collection", "retags", "retags", "n/a", "n/a", "-"},
        "recovery_spans_single" => {"collection", "retags", "n/a", "n/a", "n/a", "1.6-d"},
        "tombstone_declared_count" => {"scalar", "admits", "n/a", "1024", "1025", "1.6-d"}
      }

      removals = ["admits", "crashes", "retags", "silent", "combined", "n/a"]
      rows = corpus()

      assert length(rows) == map_size(inventory), "the manifest has a duplicate or missing row"
      assert MapSet.new(rows, & &1.site) == MapSet.new(Map.keys(inventory))

      for r <- rows do
        assert {r.kind, r.go_removal, r.ex_removal, r.at, r.over, r.owner} == inventory[r.site],
               "#{r.site}: the manifest and the inventory disagree"

        # Only the DECLARED-SCALAR rule freezes a ceiling here; a collection's ceiling belongs
        # to the count corpus, and restating it would be a second inventory to keep in sync.
        assert r.at != "n/a" == (r.kind == "scalar"),
               "#{r.site}: kind=#{r.kind} but at=#{r.at}"

        assert r.at == "n/a" == (r.over == "n/a"),
               "#{r.site}: at and over must both be set or both be n/a"

        assert r.ex_removal in removals and r.go_removal in removals,
               "#{r.site}: removal tokens #{r.go_removal}/#{r.ex_removal} are not both known"

        assert {r.zero, r.one} == {"refuse", "accept"},
               "#{r.site}: a lower bound of 1 is zero=refuse/one=accept"

        assert r.ex_removal == "n/a" == (r.owner != "-"),
               "#{r.site}: an absent peer must name an owner and a present one must not"
      end
    end
  end

  describe "plan collections" do
    test "plan_pages_decoded and plan_pages_raw" do
      raw = row("plan_pages_raw")
      {h, pages} = plan()

      assert {:error, :page_bounds} = PlanValidate.validate(h, [])
      # ONE PAGE IS ADMITTED -- without it a validator demanding two would satisfy the row.
      assert {:ok, _} = PlanValidate.validate(h, pages)

      header_bytes = ScheduledPlanHeaderV1.encode(h)
      raw_pages = Enum.map(pages, &ScheduledPlanPageV1.encode/1)

      assert {:error, :page_bounds} =
               AssignmentValidate.validate_bytes_against_plan_bytes(<<>>, header_bytes, [])

      # A COMBINED GATE, so this row records the BOUNDARY only. `bound_page_count/2` is one
      # conjunction over the declared count, the ceiling and the supplied length -- there is no
      # zero arm to remove on its own, and the manifest says so rather than implying a proof.
      assert raw.ex_removal == "combined"

      # ONE PAGE ACCEPTED THROUGH THE PUBLIC BOUNDARY, with a VALID assignment bound to this
      # plan. `validate_bytes_against_plan_bytes/3` validates the record and its plan relation
      # after the count gate, so an empty record can only ever yield an error -- and a row
      # asserting `{:error, _}` stays green with the minimum tightened to two pages, which is
      # exactly the drift the acceptance exists to catch.
      record = SweepAssignmentRecordV1.encode(assignment_for(h, pages))

      assert {:ok, _} =
               AssignmentValidate.validate_bytes_against_plan_bytes(
                 record,
                 header_bytes,
                 raw_pages
               )
    end

    test "plan_ranges -- the load-bearing plan arm" do
      r = row("plan_ranges")
      assert r.ex_removal == "admits"

      {h, pages} = plan()
      assert {:ok, _} = PlanValidate.validate(h, pages)

      # RESEALED so the empty page is refused by its OWN rule and not by a stale digest,
      # declared total or commitment.
      page = %{hd(pages) | ranges: []}
      page = %{page | page_sha256: HashGrammar.plan_page_digest(page)}
      {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment([page])

      eh = %{
        h
        | plan_root_sha256: HashGrammar.plan_root([page]),
          total_target_count: 0,
          mtr_ordinal_range_commitment: commitment
      }

      eh = %{eh | execution_plan_sha256: HashGrammar.plan_header_digest(eh)}

      assert {:error, :page_bounds} = PlanValidate.validate(eh, [page])
    end
  end

  describe "recovery collections" do
    test "recovery_pages_decoded and recovery_pages_raw" do
      decoded = row("recovery_pages_decoded")
      pages = [manifest_page()]
      root = HashGrammar.manifest_root(pages)

      assert {:error, :manifest_empty} = RecoveryValidate.manifest_chain([], root)
      assert :ok = RecoveryValidate.manifest_chain(pages, root)

      raw = Enum.map(pages, &EdgeLossManifestPageV1.encode/1)
      assert {:error, :manifest_empty} = RecoveryValidate.manifest_chain_from_raw([], root)
      assert :ok = RecoveryValidate.manifest_chain_from_raw(raw, root)

      # THE DECODED ARM IS NOT MERELY A VERDICT here either: removing its clause leaves the
      # remaining head matching an empty list and raising, so it is what keeps a public
      # validator from crashing on attacker-supplied input.
      assert decoded.ex_removal == "crashes"
    end

    test "recovery_spans_chain" do
      r = row("recovery_spans_chain")
      pages = [manifest_page()]

      assert :ok = RecoveryValidate.manifest_chain(pages, HashGrammar.manifest_root(pages))

      empty = %{hd(pages) | classification_spans: []}
      empty = %{empty | page_sha256: HashGrammar.manifest_page_digest(empty)}

      # THE EXACT REFUSAL REASON, not merely "refused": the arm is `retags`, so with the local
      # check removed the boundary still refuses under the span-body reason. Asserting the
      # reason is what makes this row kill that removal.
      assert r.ex_removal == "retags"

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain([empty], HashGrammar.manifest_root([empty]))
    end
  end

  describe "sites with no peer here" do
    test "the single-page span site and the signed declared count are 1.6-d's" do
      for site <- ["recovery_spans_single", "tombstone_declared_count"] do
        r = row(site)
        assert r.ex_removal == "n/a"
        assert r.owner == "1.6-d"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # adapters
  # ---------------------------------------------------------------------------

  defp plan do
    h = "plan_header.bin" |> fixture() |> ScheduledPlanHeaderV1.decode()
    p = "plan_page.bin" |> fixture() |> ScheduledPlanPageV1.decode()

    # ZERO MTR, stated explicitly and RESEALED. The committed range admits two ordinals while
    # the committed assignment expects none, so an accepted control built from both unchanged
    # is refused for the MTR RELATION -- another rule's outcome standing in for this one's.
    ranges =
      Enum.map(p.ranges, fn r ->
        r = %{r | mtr_ordinal_count: 0, mtr_admission_budget: 0}
        %{r | range_sha256: HashGrammar.range_digest(r)}
      end)

    page = %{p | page_index: 0, page_count: 1, prev_page_sha256: <<>>, ranges: ranges}
    page = %{page | page_sha256: HashGrammar.plan_page_digest(page)}
    {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment([page])

    h = %{
      h
      | page_count: 1,
        plan_root_sha256: HashGrammar.plan_root([page]),
        total_target_count: Enum.sum(Enum.map(page.ranges, & &1.target_count)),
        mtr_ordinal_range_commitment: commitment
    }

    {%{h | execution_plan_sha256: HashGrammar.plan_header_digest(h)}, [page]}
  end

  # EXACTLY ONE SPAN. The committed fixture carries THREE, so using it unchanged would have
  # proved that a three-span page is admitted -- true, and not the claim. A minimum of 1 is
  # pinned only by admitting a page carrying exactly one. The page digest is resealed after the
  # reduction, and every caller recomputes the manifest root from the page it actually built.
  # A VALID assignment BOUND TO THIS PLAN: only the fields that bind a record to a plan are
  # re-pointed, so the accepted control differs from the refused one in page count alone.
  defp assignment_for(header, pages) do
    range = hd(hd(pages).ranges)
    base = "assignment_zero_mtr.bin" |> fixture() |> SweepAssignmentRecordV1.decode()

    %{
      base
      | execution_plan_id: header.execution_plan_id,
        execution_plan_sha256: header.execution_plan_sha256,
        network_scope_id: header.network_scope_id,
        target_range_id: range.range_id,
        target_range_sha256: range.range_sha256,
        availability_policy_id: header.availability_policy_id,
        check_set_sha256: header.check_set_sha256
    }
  end

  defp manifest_page do
    p = "manifest_page.bin" |> fixture() |> EdgeLossManifestPageV1.decode()

    page = %{
      p
      | page_index: 0,
        page_count: 1,
        prev_page_sha256: <<>>,
        terminal: true,
        classification_spans: Enum.take(p.classification_spans, 1)
    }

    %{page | page_sha256: HashGrammar.manifest_page_digest(page)}
  end

  # ---------------------------------------------------------------------------
  # manifest
  # ---------------------------------------------------------------------------

  defp row(site),
    do: Enum.find(corpus(), &(&1.site == site)) || flunk("no lower-bound row for #{site}")

  defp corpus do
    corpus_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(fn line ->
      case String.split(String.trim(line), ~r/\s+/) do
        [site, kind, zero, one, at, over, go_removal, ex_removal, owner] ->
          %{
            site: site,
            kind: kind,
            zero: zero,
            one: one,
            at: at,
            over: over,
            go_removal: go_removal,
            ex_removal: ex_removal,
            owner: owner
          }

        other ->
          flunk("lower-bound row #{inspect(other)} does not have 9 fields")
      end
    end)
  end

  defp corpus_path,
    do: Path.expand("../../../../../proto/edge/v1/testdata/lower_bound_corpus.txt", __DIR__)

  defp fixture(name), do: corpus_path() |> Path.dirname() |> Path.join(name) |> File.read!()
end
