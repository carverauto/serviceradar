defmodule ServiceRadar.Edge.RecoveryProjectionCostTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecoveryProjectionCost, as: Cost
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1

  test "whole-manifest independent vectors charge finalization regardless of page grouping" do
    for {count, rows, bytes} <- [
          {0, 16, 1_048_576},
          {1, 22, 1_081_344},
          {256, 1552, 9_437_184},
          {1024, 6160, 34_603_008}
        ] do
      pages = pages(count)
      assert {:ok, %{rows: ^rows, bytes: ^bytes}} = Cost.required(pages)
      assert :ok = Cost.validate(pages, %{rows: rows, bytes: bytes})

      assert {:error, :recovery_projection_cost} =
               Cost.validate(pages, %{rows: rows - 1, bytes: bytes})

      assert {:error, :recovery_projection_cost} =
               Cost.validate(pages, %{rows: rows, bytes: bytes - 1})
    end

    assert Cost.required(pages(256)) == Cost.required(pages(256, 64))
    assert :ok = Cost.validate(pages(1), %{rows: 8192, bytes: 34_603_008})

    assert {:error, :recovery_projection_cost} =
             Cost.validate(pages(1), %{rows: 8193, bytes: 34_603_008})

    assert {:error, :recovery_projection_cost} =
             Cost.validate(pages(1), %{rows: 8192, bytes: 34_603_009})
  end

  test "cost traversal refuses malformed and over-budget manifest collections" do
    for pages <- [
          nil,
          [%{}],
          pages(1025),
          pages(257, 257),
          List.duplicate(%EdgeLossManifestPageV1{}, 1025)
        ] do
      assert {:error, :recovery_projection_cost} = Cost.required(pages)
    end
  end

  defp pages(count, chunk \\ 256) do
    %EdgeClassificationSpanV1{}
    |> List.duplicate(count)
    |> Enum.chunk_every(chunk)
    |> Enum.map(&%EdgeLossManifestPageV1{classification_spans: &1})
  end
end
