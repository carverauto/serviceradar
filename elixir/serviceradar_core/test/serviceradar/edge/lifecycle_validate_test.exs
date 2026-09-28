defmodule ServiceRadar.Edge.LifecycleValidateTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.LifecycleValidate
  alias Serviceradar.Edge.V1.SweepExecutionEventV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "lifecycle_corpus.txt")
  @external_resource @manifest

  test "decoded lifecycle boundary agrees with every Go-authored structural fixture" do
    names =
      for line <- @manifest |> File.read!() |> String.split("\n", trim: true) do
        [name, accepted] = String.split(line)
        result = name |> fixture() |> LifecycleValidate.validate()

        if accepted == "true" do
          assert result == :ok, "#{name}: #{inspect(result)}"
        else
          assert {:error, reason} = result, name
          refute match?({:schema_unavailable, _}, reason), name
        end

        name
      end

    files =
      @testdata
      |> Path.join("lifecycle_structural_*.bin")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert Enum.sort(names) == Enum.sort(files)
  end

  test "retired tag 20 is refused on the public decoded boundary" do
    assert {:error, :unknown_fields} =
             "lifecycle_structural_retired_tag.bin" |> fixture() |> LifecycleValidate.validate()
  end

  test "malformed decoded values refuse without raising or numeric truncation" do
    event = fixture("lifecycle_structural_completed.bin")

    for bad <- [
          nil,
          %{},
          Map.delete(event, :execution_id),
          %{event | terminal_batch_sequence: -1},
          %{event | execution_shard: 4_294_967_296},
          %{event | emitted_at_unix_nano: 9_223_372_036_854_775_808},
          %{event | hosts_observed: 1.0},
          %{event | abort_reason: <<255>>}
        ] do
      assert {:error, :shape} = LifecycleValidate.validate(bad)
    end
  end

  defp fixture(name),
    do: @testdata |> Path.join(name) |> File.read!() |> SweepExecutionEventV1.decode()
end
