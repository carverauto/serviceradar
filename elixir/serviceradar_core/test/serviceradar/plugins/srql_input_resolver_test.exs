defmodule ServiceRadar.Plugins.SRQLInputResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.SRQLInputResolver

  defmodule RunnerStub do
    @moduledoc false
    def query(query, _opts) do
      send(self(), {:srql_query, query})

      {:ok, [%{"uid" => "sr:device:1", "agent_id" => "agent-1"}]}
    end
  end

  defmodule ErrorRunnerStub do
    @moduledoc false
    def query(_query, _opts), do: {:error, :translate_failed}
  end

  test "resolve normalizes missing in: prefix from entity" do
    defs = [%{name: "devices", entity: "devices", query: "vendor:AXIS"}]

    assert {:ok, [%{query: query, rows: rows}]} =
             SRQLInputResolver.resolve(defs, runner: RunnerStub)

    assert query == "in:devices vendor:AXIS"
    assert rows == [%{"uid" => "sr:device:1", "agent_id" => "agent-1"}]
    assert_received {:srql_query, "in:devices vendor:AXIS"}
  end

  test "resolve rewrites query when declared entity mismatches input entity" do
    defs = [%{name: "interfaces", entity: "interfaces", query: "in:devices vendor:AXIS"}]

    assert {:ok, [%{query: query}]} = SRQLInputResolver.resolve(defs, runner: RunnerStub)
    assert query == "in:interfaces in:devices vendor:AXIS"
  end

  test "resolve rejects unsupported entities" do
    defs = [%{name: "flows", entity: "flows", query: "in:flows"}]

    assert {:error, errors} = SRQLInputResolver.resolve(defs, runner: RunnerStub)
    assert Enum.any?(errors, &String.contains?(&1, "unsupported input entity"))
  end

  test "resolve returns formatted error when query fails" do
    defs = [%{name: "devices", entity: "devices", query: "in:devices"}]

    assert {:error, [message]} = SRQLInputResolver.resolve(defs, runner: ErrorRunnerStub)
    assert String.contains?(message, "failed to execute SRQL input query")
  end

  test "resolve carries validated projected fields for devices" do
    defs = [
      %{
        name: "targets",
        entity: "devices",
        query: "in:devices",
        fields: [
          "switch_port_attachment",
          "metadata.armis_access_switch",
          "switch_port_attachment"
        ]
      }
    ]

    assert {:ok, [%{fields: fields}]} = SRQLInputResolver.resolve(defs, runner: RunnerStub)
    assert fields == ["switch_port_attachment", "metadata.armis_access_switch"]
  end

  test "resolve rejects invalid projected fields" do
    for fields <- [
          ["metadata"],
          ["Switch Port"],
          ["metadata.a.b"],
          ["uid; drop"],
          "switch_port_attachment"
        ] do
      defs = [%{name: "targets", entity: "devices", query: "in:devices", fields: fields}]
      assert {:error, [_message]} = SRQLInputResolver.resolve(defs, runner: RunnerStub)
    end

    defs = [%{name: "ifs", entity: "interfaces", query: "in:interfaces", fields: ["if_name"]}]

    assert {:error, ["input fields are only supported for devices"]} =
             SRQLInputResolver.resolve(defs, runner: RunnerStub)
  end
end
