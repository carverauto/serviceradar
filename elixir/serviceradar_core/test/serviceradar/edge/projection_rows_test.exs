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
end
