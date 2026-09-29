defmodule ServiceRadar.Edge.ProjectedCostCorpusTest do
  @moduledoc "Shared pre-signature cost relations through the raw record boundary."
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecordValidate

  @corpus "projected_cost_corpus.txt"

  test "every conjunct has both runtime verdicts" do
    rows = corpus()

    # EXACTLY the three conjuncts the relation has. A fourth arriving without a peer, or one
    # disappearing, is drift the Go side alone would not surface as an ownership question.
    assert MapSet.new(rows, & &1.conjunct) ==
             MapSet.new(["cost_model_version", "projected_row_count", "projected_write_bytes"])

    assert length(rows) == 3, "the manifest repeats a conjunct"

    for r <- rows do
      assert r.elixir == "refuse"
      assert r.owner == "-"
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

  test "each manifest relation accepts equality and refuses its independent mismatch" do
    base = Path.dirname(corpus_path())

    for r <- corpus() do
      assert {:ok, control} =
               base
               |> Path.join("record_boundary_control.bin")
               |> File.read!()
               |> RecordValidate.validate_bytes()

      {:production, claims} = control.production_capability.claims

      field =
        case r.conjunct do
          "cost_model_version" -> :cost_model_version
          "projected_row_count" -> :max_projected_row_count
          "projected_write_bytes" -> :max_projected_write_bytes
        end

      assert Map.fetch!(control, String.to_existing_atom(r.conjunct)) == Map.fetch!(claims, field)

      assert {:error, :production_grant} =
               base
               |> Path.join("record_boundary_production_#{field}.bin")
               |> File.read!()
               |> RecordValidate.validate_bytes()
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
