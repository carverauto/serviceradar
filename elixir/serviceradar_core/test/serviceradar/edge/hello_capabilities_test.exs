defmodule ServiceRadar.Edge.HelloCapabilitiesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.HelloCapabilities
  alias Serviceradar.Edge.V1.EdgeRecordCapabilitiesV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "hello_capabilities_corpus.txt")
  @external_resource @manifest

  defp read(name), do: File.read!(Path.join(@testdata, name))
  defp capabilities(name), do: name |> read() |> EdgeRecordCapabilitiesV1.decode()

  test "shared committed corpus compares sets and refuses every duplicate dimension" do
    base = capabilities("hello_capabilities_control.bin")
    rows = @manifest |> File.read!() |> String.split("\n", trim: true)

    expected = %{
      "equal" => :ok,
      "conflict" => {:error, :capability_conflict},
      "duplicate" => {:error, :capability_duplicate}
    }

    for row <- rows do
      [name, verdict] = String.split(row)
      candidate = capabilities(name)
      assert HelloCapabilities.compare(base, candidate) == Map.fetch!(expected, verdict), name
      assert HelloCapabilities.compare(candidate, base) == Map.fetch!(expected, verdict), name

      if verdict == "duplicate" do
        assert HelloCapabilities.compare(candidate, candidate) == {:error, :capability_duplicate}
      end
    end

    fields = Map.values(EdgeRecordCapabilitiesV1.__message_props__().field_props)

    required =
      ["hello_capabilities_control.bin equal", "hello_capabilities_permuted.bin equal"] ++
        Enum.flat_map(fields, fn f ->
          difference = "hello_capabilities_different_#{f.name_atom}.bin conflict"

          if f.repeated?,
            do: [difference, "hello_capabilities_duplicate_#{f.name_atom}.bin duplicate"],
            else: [difference]
        end)

    assert Enum.sort(rows) == Enum.sort(required)
  end

  test "both Hello RPCs carry the same typed advertisement and retain legacy capabilities" do
    agent = "hello_agent.bin" |> read() |> Monitoring.AgentHelloRequest.decode()
    control = "hello_control_stream.bin" |> read() |> Monitoring.ControlStreamHello.decode()
    expected = capabilities("hello_capabilities_control.bin")
    assert agent.capabilities == ["icmp"]
    assert control.capabilities == ["icmp"]
    assert agent.edge_record_capabilities == expected
    assert control.edge_record_capabilities == expected

    assert :ok =
             HelloCapabilities.compare(
               agent.edge_record_capabilities,
               control.edge_record_capabilities
             )
  end

  test "absence is no support, not an empty present advertisement" do
    assert :ok = HelloCapabilities.compare(nil, nil)

    assert {:error, :capability_conflict} =
             HelloCapabilities.compare(nil, %EdgeRecordCapabilitiesV1{})

    assert {:error, :capability_conflict} =
             HelloCapabilities.compare(%EdgeRecordCapabilitiesV1{}, nil)

    assert {:error, :capability_invalid} = HelloCapabilities.compare(:invalid, nil)
  end
end
