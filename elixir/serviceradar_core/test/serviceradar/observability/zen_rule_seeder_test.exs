defmodule ServiceRadar.Observability.ZenRuleSeederTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.ZenRuleSeeder
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @legacy_snmp_body_expression "(body == 'logs.snmp.processed' or body == '') ? (len(varbinds ?? []) > 0 ? (extract(varbinds[0].value ?? '', '^[^:]+: (.*)$')[1] ?? varbinds[0].value ?? body) : body) : body"
  @current_snmp_body_expression "(((body ?? '') == '') or body == 'logs.snmp.processed') ? (len(varbinds ?? []) > 0 ? (extract(varbinds[0].value ?? '', '^[^:]+: (.*)$')[1] ?? varbinds[0].value ?? body ?? '') : (body ?? '')) : body"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:test)}
  end

  test "seed_all refreshes the default snmp rule when the compiled definition is stale", %{
    actor: actor
  } do
    rule = fetch_snmp_rule!(actor)
    stale_compiled = replace_body_expression(rule.compiled_jdm, @legacy_snmp_body_expression)

    Repo.query!(
      """
      UPDATE platform.zen_rules
      SET compiled_jdm = $1::jsonb,
          jdm_definition = NULL
      WHERE id = $2::uuid
      """,
      [Jason.encode!(stale_compiled), rule.id]
    )

    assert body_expression(fetch_snmp_rule!(actor).compiled_jdm) == @legacy_snmp_body_expression

    assert :ok = ZenRuleSeeder.seed_all()

    refreshed = fetch_snmp_rule!(actor)
    assert is_nil(refreshed.jdm_definition)
    assert body_expression(refreshed.compiled_jdm) == @current_snmp_body_expression
  end

  test "seed_all preserves user-authored snmp rule overrides", %{actor: actor} do
    rule = fetch_snmp_rule!(actor)
    custom_jdm = replace_body_expression(rule.compiled_jdm, "'custom override'")

    assert {:ok, _updated} =
             rule
             |> Ash.Changeset.for_update(
               :update,
               %{jdm_definition: custom_jdm},
               actor: actor,
               context: %{skip_zen_sync: true}
             )
             |> Ash.update()

    assert :ok = ZenRuleSeeder.seed_all()

    refreshed = fetch_snmp_rule!(actor)
    assert refreshed.jdm_definition == custom_jdm
    assert body_expression(refreshed.compiled_jdm) == "'custom override'"
  end

  defp fetch_snmp_rule!(actor) do
    query =
      ZenRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "snmp_severity" and subject == "logs.snmp")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    rule
  end

  defp body_expression(compiled_jdm) do
    compiled_jdm
    |> Map.fetch!("nodes")
    |> Enum.find(&(&1["id"] == "setSeverity"))
    |> Map.fetch!("content")
    |> Map.fetch!("expressions")
    |> Enum.find(&(&1["key"] == "body"))
    |> Map.fetch!("value")
  end

  defp replace_body_expression(compiled_jdm, expression) do
    replace_body_expression_fallback(compiled_jdm, expression)
  end

  defp replace_body_expression_fallback(compiled_jdm, expression) do
    update_in(compiled_jdm["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "setSeverity", "content" => %{"expressions" => expressions} = content} = node ->
          updated_expressions =
            Enum.map(expressions, fn
              %{"key" => "body"} = expr -> Map.put(expr, "value", expression)
              expr -> expr
            end)

          Map.put(node, "content", Map.put(content, "expressions", updated_expressions))

        node ->
          node
      end)
    end)
  end
end
