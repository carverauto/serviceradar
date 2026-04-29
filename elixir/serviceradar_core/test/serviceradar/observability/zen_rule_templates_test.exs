defmodule ServiceRadar.Observability.ZenRuleTemplatesTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.ZenRuleTemplates

  @snmp_body_expression "(((body ?? '') == '') or body == 'logs.snmp.processed') ? (len(varbinds ?? []) > 0 ? (extract(varbinds[0].value ?? '', '^[^:]+: (.*)$')[1] ?? varbinds[0].value ?? body ?? '') : (body ?? '')) : body"

  test "snmp severity template uses supported fallback expression syntax" do
    assert {:ok, compiled} = ZenRuleTemplates.compile(:snmp_severity, %{})

    expressions =
      compiled
      |> Map.fetch!("nodes")
      |> Enum.find(&(&1["id"] == "setSeverity"))
      |> Map.fetch!("content")
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

    assert body_expression == @snmp_body_expression

    refute String.contains?(severity_expression, "coalesce(")
  end

  test "coraza WAF template writes the generic security signal shape" do
    assert {:ok, compiled} = ZenRuleTemplates.compile(:coraza_waf, %{})

    expressions =
      compiled
      |> Map.fetch!("nodes")
      |> Enum.find(&(&1["id"] == "normalizeCorazaWaf"))
      |> Map.fetch!("content")
      |> Map.fetch!("expressions")

    assert Enum.any?(expressions, &(&1["key"] == "attributes.event_type"))
    assert Enum.any?(expressions, &(&1["key"] == "attributes.security.signal.kind"))
    assert Enum.any?(expressions, &(&1["key"] == "attributes.security.signal.source"))
    assert Enum.any?(expressions, &(&1["key"] == "attributes.waf.rule_id"))
    assert Enum.any?(expressions, &(&1["key"] == "attributes.waf.client_ip"))
  end

  test "templates can be loaded from configured external directories" do
    template_dir =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-zen-templates-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(template_dir)

    template = %{
      "nodes" => [
        %{"id" => "inputNode", "type" => "inputNode"},
        %{"id" => "outputNode", "type" => "outputNode"}
      ],
      "edges" => []
    }

    File.write!(Path.join(template_dir, "custom_waf.json"), Jason.encode!(template))

    previous = System.get_env("SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS")

    try do
      System.put_env("SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS", template_dir)
      assert {:ok, ^template} = ZenRuleTemplates.compile("custom_waf", %{})
    after
      restore_env("SERVICERADAR_ZEN_RULE_TEMPLATE_DIRS", previous)
      File.rm_rf!(template_dir)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
