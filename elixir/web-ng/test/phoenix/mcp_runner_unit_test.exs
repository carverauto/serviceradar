defmodule ServiceRadarWebNG.McpRunnerUnitTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Mcp.Runner
  alias ServiceRadarWebNG.TestSupport.McpSRQLTranslationProbe

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, McpSRQLTranslationProbe)

    on_exit(fn -> restore_srql_module(previous) end)
  end

  test "execute_srql uses an in-query limit unless the tool limit is explicitly set" do
    context = %{context: %{scope: %{permissions: MapSet.new(["devices.view"])}}}

    cases = [
      {%{query: "in:devices limit:3"}, 3},
      {%{query: "in:devices limit:3", limit: nil}, 3},
      {%{query: "in:devices limit:3", limit: 2}, 2},
      {%{query: "in:devices limit:3", limit: 10_000}, 500}
    ]

    for {arguments, expected_limit} <- cases do
      input = %{arguments: arguments}

      assert {:ok, %{"pagination" => %{"limit" => ^expected_limit}}} =
               Runner.execute_srql(input, context)
    end
  end

  defp restore_srql_module(nil), do: Application.delete_env(:serviceradar_web_ng, :srql_module)

  defp restore_srql_module(module), do: Application.put_env(:serviceradar_web_ng, :srql_module, module)
end
