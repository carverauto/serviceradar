defmodule ServiceRadarWebNGWeb.SRQL.BuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder

  test "parse supports quoted filter values with spaces" do
    query = ~s|in:devices type:"Access Point" sort:last_seen:desc limit:20|

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "devices"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "type" and filter["op"] == "equals" and
               filter["value"] == "Access Point"
           end)
  end

  test "build after parsing quoted values remains builder-compatible" do
    query = ~s|in:devices type:"Access Point"|

    assert {:ok, parsed} = Builder.parse(query)
    rebuilt = Builder.build(parsed)
    assert rebuilt =~ "in:devices"
    assert rebuilt =~ "type:Access\\ Point"
  end

  test "parse supports escaped spaces in unquoted filter values" do
    query = ~s|in:devices vendor_name:Access\ Point sort:last_seen:desc limit:20|

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "devices"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "vendor_name" and filter["op"] == "equals" and
               filter["value"] == "Access Point"
           end)
  end
end
