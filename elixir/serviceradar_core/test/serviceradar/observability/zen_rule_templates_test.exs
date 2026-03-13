defmodule ServiceRadar.Observability.ZenRuleTemplatesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ZenRuleTemplates

  test "snmp severity template uses supported fallback expression syntax" do
    assert {:ok, compiled} = ZenRuleTemplates.compile(:snmp_severity, %{})

    expressions =
      compiled
      |> Map.fetch!("nodes")
      |> Enum.find(&(&1["id"] == "setSeverity"))
      |> then(&Map.fetch!(&1, "content"))
      |> Map.fetch!("expressions")

    severity_expression =
      expressions
      |> Enum.find(&(&1["key"] == "severity"))
      |> Map.fetch!("value")

    source_expression =
      expressions
      |> Enum.find(&(&1["key"] == "source"))
      |> Map.fetch!("value")

    service_name_expression =
      expressions
      |> Enum.find(&(&1["key"] == "service_name"))
      |> Map.fetch!("value")

    body_expression =
      expressions
      |> Enum.find(&(&1["key"] == "body"))
      |> Map.fetch!("value")

    assert severity_expression == "severity ?? 'Unknown'"
    assert source_expression == "'snmp'"
    assert service_name_expression == "'snmp'"

    assert body_expression ==
             "(body == 'logs.snmp.processed' or body == '') ? (len(varbinds ?? []) > 0 ? (extract(varbinds[0].value ?? '', '^[^:]+: (.*)$')[1] ?? varbinds[0].value ?? body) : body) : body"

    refute String.contains?(severity_expression, "coalesce(")
  end
end
