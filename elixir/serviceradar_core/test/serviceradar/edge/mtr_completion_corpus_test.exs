defmodule ServiceRadar.Edge.MtrCompletionCorpusTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.HashGrammar

  @manifest Path.expand(
              "../../../../../proto/edge/v1/testdata/mtr_completion_disposition_corpus.txt",
              __DIR__
            )
  @external_resource @manifest

  test "every frozen disposition consumes the shared leaf input and preimage" do
    rows = @manifest |> File.read!() |> String.split("\n", trim: true)

    values =
      for row <- rows do
        [value, verdict, ordinal, trace, range, plan, commitment, preimage, root] =
          String.split(row)

        value = String.to_integer(value)
        ordinal = String.to_integer(ordinal)
        trace = decode_hex(trace)
        range = decode_hex(range)
        plan = decode_hex(plan)
        commitment = decode_hex(commitment)
        leaf = {ordinal, value, trace, range}
        result = HashGrammar.mtr_completion_verify([leaf], 0, 1, plan, commitment)

        case verdict do
          "accept" ->
            assert result == {:ok, decode_hex(root)}, row

            assert decode_hex(preimage) ==
                     <<2::64, ordinal::64, value::64, byte_size(trace)::64, trace::binary, 32::64,
                       range::binary>>

          "reject" ->
            assert result == :error, row
            assert preimage == "-" and root == "-"
        end

        {value, verdict}
      end

    assert Enum.sort(values) ==
             Enum.sort(
               Enum.map(1..5, &{&1, "accept"}) ++
                 Enum.map([0, -1, 6, 999], &{&1, "reject"})
             )
  end

  defp decode_hex("-"), do: <<>>
  defp decode_hex(value), do: Base.decode16!(value, case: :lower)
end
