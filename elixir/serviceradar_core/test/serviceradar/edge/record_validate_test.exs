defmodule ServiceRadar.Edge.RecordValidateTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecordValidate

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "record_boundary_corpus.txt")
  @external_resource @manifest

  test "raw record boundary agrees with Go on every structural fixture" do
    entries = @manifest |> File.read!() |> String.split("\n", trim: true)

    names =
      for entry <- entries do
        [name, accepted] = String.split(entry)
        result = name |> fixture() |> RecordValidate.validate_bytes()

        if accepted == "true" do
          assert {:ok, _record} = result, "#{name}: #{inspect(result)}"
        else
          assert {:error, reason} = result, name
          refute match?({:wire, _}, reason), "#{name}: structural refusal required"
        end

        name
      end

    fixtures =
      @testdata
      |> Path.join("record_boundary_*.bin")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert Enum.sort(names) == Enum.sort(fixtures)
  end

  test "record principal call enforces the lower and upper bounds" do
    for n <- [0, 1, 128, 129] do
      result =
        "record_boundary_principal_#{n}.bin" |> fixture() |> RecordValidate.validate_bytes()

      if n in [1, 128],
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, :principal})
    end
  end

  test "declared costs are checked against production claims" do
    for name <- ["cost_model_version", "max_projected_row_count", "max_projected_write_bytes"] do
      assert {:error, :production_grant} =
               "record_boundary_production_#{name}.bin"
               |> fixture()
               |> RecordValidate.validate_bytes()
    end
  end

  test "nonbytes and malformed raw input refuse without raising" do
    for raw <- [nil, false, %{}, 7, <<255>>, <<10, 128>>, <<0>>] do
      assert {:error, {:wire, _}} = RecordValidate.validate_bytes(raw)
    end
  end

  test "raw byte ceiling and wire hygiene precede structural validation" do
    assert {:error, {:wire, :too_large}} =
             RecordValidate.validate_bytes(:binary.copy(<<0>>, 524_289))

    # Unknown varint field 100 appended to an otherwise valid record.
    assert {:error, {:wire, _}} =
             RecordValidate.validate_bytes(
               fixture("record_boundary_control.bin") <> <<160, 6, 1>>
             )
  end

  defp fixture(name), do: File.read!(Path.join(@testdata, name))
end
