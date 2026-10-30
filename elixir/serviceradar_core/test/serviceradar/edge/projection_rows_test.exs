defmodule ServiceRadar.Edge.ProjectionRowsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ProjectionRows
  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "projection_rows_corpus.txt")
  @external_resource @manifest

  test "every committed positive batch has the same enumerated rows and count as Go" do
    entries = @manifest |> File.read!() |> String.split("\n", trim: true)

    names =
      for entry <- entries do
        [name, family, count, encoded] = String.split(entry)
        raw = File.read!(Path.join(@testdata, name))

        {rows, actual_count} =
          case family do
            "sweep" ->
              batch = SweepObservationBatchV1.decode(raw)
              {ProjectionRows.sweep(batch), ProjectionRows.sweep_count(batch)}

            "mtr" ->
              batch = MtrTraceBatchV1.decode(raw)
              {ProjectionRows.mtr(batch), ProjectionRows.mtr_count(batch)}
          end

        expected_rows =
          if encoded == "-" do
            []
          else
            for coordinate <- String.split(encoded, ",") do
              [kind, batch_index, element_index] = String.split(coordinate, ":")
              {kind, String.to_integer(batch_index), String.to_integer(element_index)}
            end
          end

        assert rows == expected_rows, name
        assert length(rows) == actual_count, name
        assert actual_count == String.to_integer(count), name
        assert MapSet.size(MapSet.new(rows)) == actual_count, name
        name
      end

    fixtures =
      @testdata |> Path.join("*batch.bin") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    assert Enum.sort(names) == Enum.sort(fixtures)
  end

  describe "row_key/2" do
    # Golden vectors captured directly from go/pkg/edge/projection.RowKey (the
    # same inputs as its own TestRowKeyStableAndDistinct), so this is a
    # cross-language parity check, not merely a self-consistency one.
    @digest "semantic-digest-32-bytes-example"
    @other_digest "different-digest-32-bytes-exampl"

    test "matches the Go implementation's golden vectors" do
      assert Base.encode16(ProjectionRows.row_key(@digest, 0), case: :lower) ==
               "b15d4c18d460640db54232a474ecda7980de296369a3bbed866a55e56fb4ba86"

      assert Base.encode16(ProjectionRows.row_key(@digest, 1), case: :lower) ==
               "b8bd58e77693553bd9fb2aba6b82278167c688f551782b184c98bbcb4179e683"

      assert Base.encode16(ProjectionRows.row_key(@digest, 42), case: :lower) ==
               "5e281ad86f1c2c8080029a892c31321fe04780e2e93f71c0c22754f830b02355"

      assert Base.encode16(ProjectionRows.row_key(@other_digest, 0), case: :lower) ==
               "85a98ec14d56c748d5020e962897f3378cf5c2e7f1988130499f42a5349086d5"

      assert Base.encode16(ProjectionRows.row_key("", 0), case: :lower) ==
               "374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb"
    end

    test "stable for the same (digest, ordinal), distinct across ordinals and digests" do
      a = ProjectionRows.row_key(@digest, 0)

      assert a == ProjectionRows.row_key(@digest, 0)
      assert a != ProjectionRows.row_key(@digest, 1)
      assert a != ProjectionRows.row_key(@other_digest, 0)
      assert byte_size(a) == 32
    end
  end
end
