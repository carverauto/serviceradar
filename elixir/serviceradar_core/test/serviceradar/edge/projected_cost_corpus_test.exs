defmodule ServiceRadar.Edge.ProjectedCostCorpusTest do
  @moduledoc """
  Task 1.5-h: the PROJECTED-COST RELATION, this runtime's half -- which is a RECORDED GAP.

  THIS RUNTIME DOES NOT COMPARE THESE FIELDS. `cost_model_version`, `projected_row_count` and
  `projected_write_bytes` are DIGESTED here -- by `SemanticDigest` and `ClaimsFraming` -- and
  never checked against the production capability's declared maxima. Go performs that
  comparison inside `ValidateRecord`; there is no peer here to run the same vectors against,
  because there is no structural record boundary for it to live in yet. 1.5-n creates one.

  ## Why this file exists at all

  A gap that is only WRITTEN DOWN drifts. If the manifest's `n/a` rows were ever quietly given
  a peer verdict, or their owner dropped, nothing in this runtime would notice -- the vectors
  do not exist here to fail. This module therefore asserts the SHAPE OF THE GAP: every conjunct
  is Go-only, every one names 1.5-n, and the conjunct set is exactly the three the relation has.

  When 1.5-n lands, these rows flip to both-runtime and this module gains real vectors; until
  then it is the thing that keeps the delegation honest.
  """
  use ExUnit.Case, async: true

  @corpus "projected_cost_corpus.txt"

  test "every conjunct is recorded Go-only with 1.5-n named" do
    rows = corpus()

    # EXACTLY the three conjuncts the relation has. A fourth arriving without a peer, or one
    # disappearing, is drift the Go side alone would not surface as an ownership question.
    assert MapSet.new(rows, & &1.conjunct) ==
             MapSet.new(["cost_model_version", "projected_row_count", "projected_write_bytes"])

    assert length(rows) == 3, "the manifest repeats a conjunct"

    for r <- rows do
      assert r.elixir == "n/a",
             "#{r.conjunct}: this runtime does not compare projected cost; a peer verdict here " <>
               "would claim a comparison that does not exist"

      assert r.owner == "1.5-n",
             "#{r.conjunct}: the peer needs the structural record boundary 1.5-n creates"

      assert r.go == "refuse"
    end
  end

  test "the relation shapes are the two the Go side enforces" do
    for r <- corpus() do
      case r.relation do
        "equal" ->
          assert {r.accepted, r.refused} == {"equal_to_claim", "differs_from_claim"}

        "at_most" ->
          # INCLUSIVITY IS HALF THE RULE, and it must survive delegation: a peer built later
          # from a manifest that had lost the at-maximum acceptance would enforce `>=`.
          assert {r.accepted, r.refused} == {"equal_to_maximum", "one_over_maximum"}

        other ->
          flunk("#{r.conjunct}: relation #{other} is not recognised")
      end
    end
  end

  defp corpus do
    corpus_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(fn line ->
      case String.split(String.trim(line), ~r/\s+/) do
        [conjunct, relation, accepted, refused, go, elixir, owner] ->
          %{
            conjunct: conjunct,
            relation: relation,
            accepted: accepted,
            refused: refused,
            go: go,
            elixir: elixir,
            owner: owner
          }

        other ->
          flunk("projected-cost row #{inspect(other)} does not have 7 fields")
      end
    end)
  end

  defp corpus_path, do: Path.expand("../../../../../proto/edge/v1/testdata/#{@corpus}", __DIR__)
end
