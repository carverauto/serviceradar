defmodule ServiceRadar.Plugins.SRQLInputResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.TestSupport.PagedSRQLRunner

  defmodule ErrorRunnerStub do
    @moduledoc false
    def query_page(_query, _opts), do: {:error, :translate_failed}
  end

  @row %{"uid" => "sr:device:1", "agent_id" => "agent-1"}

  test "resolve normalizes missing in: prefix from entity" do
    defs = [%{name: "devices", entity: "devices", query: "vendor:AXIS"}]

    assert {:ok, [%{query: query, rows: rows}]} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))

    assert query == "in:devices vendor:AXIS"
    assert rows == [@row]
    assert PagedSRQLRunner.queries() == ["in:devices vendor:AXIS sort:uid:asc"]
  end

  # SRQL answers a request that names no limit with 100 rows, so a resolver
  # that reads one page hands every caller a silently cut selection.
  test "resolve reads every page of a selection" do
    devices = Enum.map(1..2_150, &%{"uid" => "sr:device:#{&1}", "agent_id" => "agent-1"})
    defs = [%{name: "targets", entity: "devices", query: "in:devices"}]

    assert {:ok, [%{rows: rows}]} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving(devices))

    assert rows == devices
    assert length(PagedSRQLRunner.queries()) == 3
  end

  # Each page is its own offset query. Without a unique order, agents with
  # equal last_seen values can move between pages and be skipped. The device
  # default order is unique but unindexable, so every page of a fleet-wide walk
  # sorted every device row in full.
  test "agent and device selections are paged in uid order after any operator sort" do
    runner = PagedSRQLRunner.serving([%{"uid" => "uid-1"}])

    for {entity, query} <- [
          {"agents", "in:agents"},
          {"agents", "in:agents sort:last_seen:desc"},
          {"devices", "in:devices"},
          {"devices", "in:devices sort:hostname:asc"}
        ] do
      defs = [%{name: "targets", entity: entity, query: query}]
      assert {:ok, [%{query: ^query}]} = SRQLInputResolver.resolve(defs, runner: runner)
    end

    assert PagedSRQLRunner.queries() == [
             "in:agents sort:uid:asc",
             "in:agents sort:last_seen:desc sort:uid:asc",
             "in:devices sort:uid:asc",
             "in:devices sort:hostname:asc sort:uid:asc"
           ]
  end

  test "resolve rewrites query when declared entity mismatches input entity" do
    defs = [%{name: "interfaces", entity: "interfaces", query: "in:devices vendor:AXIS"}]

    assert {:ok, [%{query: query}]} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))

    assert query == "in:interfaces in:devices vendor:AXIS"
  end

  test "resolve rejects unsupported entities" do
    defs = [%{name: "flows", entity: "flows", query: "in:flows"}]

    assert {:error, errors} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))

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

    assert {:ok, [%{fields: fields}]} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))

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

      assert {:error, [_message]} =
               SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))
    end

    defs = [%{name: "ifs", entity: "interfaces", query: "in:interfaces", fields: ["if_name"]}]

    assert {:error, ["input fields are only supported for devices"]} =
             SRQLInputResolver.resolve(defs, runner: PagedSRQLRunner.serving([@row]))
  end
end
