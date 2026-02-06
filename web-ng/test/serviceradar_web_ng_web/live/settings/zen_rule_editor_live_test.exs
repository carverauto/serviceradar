defmodule ServiceRadarWebNGWeb.Settings.ZenRuleEditorLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ZenRule

  setup :register_and_log_in_user

  test "loads edit route and saves rule changes", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, rule} =
      Ash.create(
        ZenRule,
        %{
          name: "edit-zen-#{unique}",
          subject: "logs.syslog",
          template: :passthrough,
          order: 120,
          jdm_definition: %{"nodes" => [], "edges" => []}
        },
        action: :create,
        scope: scope
      )

    {:ok, lv, _html} = live(conn, ~p"/settings/rules/zen/#{rule.id}")

    assert has_element?(lv, "#zen_rule_form")

    updated_description = "Updated description #{unique}"

    lv
    |> form("#zen_rule_form", %{
      "zen_rule" => %{
        "description" => updated_description
      }
    })
    |> render_submit()

    {:ok, updated_rule} = Ash.get(ZenRule, rule.id, scope: scope)
    assert updated_rule.description == updated_description
  end
end
