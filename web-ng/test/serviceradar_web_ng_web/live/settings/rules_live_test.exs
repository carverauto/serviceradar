defmodule ServiceRadarWebNGWeb.Settings.RulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ZenRule

  setup :register_and_log_in_user

  describe "log normalization rules" do
    test "creates and deletes a Zen rule", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=logs")
      unique = System.unique_integer([:positive])
      rule_name = "syslog-clean-#{unique}"

      lv
      |> form("#zen_rule_form",
        zen_rule: %{
          name: rule_name,
          subject: "logs.syslog",
          template: "passthrough",
          order: "10"
        }
      )
      |> render_submit()

      rules = unwrap_page(Ash.read(ZenRule, scope: scope))
      rule = Enum.find(rules, &(&1.name == rule_name))

      assert rule
      assert render(lv) =~ rule_name

      lv
      |> element("button[phx-click='delete_zen'][phx-value-id='#{rule.id}']")
      |> render_click()

      rules_after = unwrap_page(Ash.read(ZenRule, scope: scope))
      refute Enum.any?(rules_after, &(&1.id == rule.id))
    end
  end

  describe "event and alert rules" do
    test "creates promotion and stateful rules", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")
      unique = System.unique_integer([:positive])

      promotion_name = "promote-errors-#{unique}"

      lv
      |> form("#promotion_rule_form",
        promotion_rule: %{
          name: promotion_name,
          priority: "10",
          enabled: "true",
          match: %{
            subject_prefix: "logs.syslog",
            severity_text: "ERROR"
          },
          event: %{
            message: "Syslog error"
          }
        }
      )
      |> render_submit()

      assert render(lv) =~ promotion_name

      stateful_name = "repeat-errors-#{unique}"

      {:ok, lv_alerts, _html} = live(conn, ~p"/settings/rules?tab=alerts")

      lv_alerts
      |> form("#stateful_rule_form",
        stateful_rule: %{
          name: stateful_name,
          signal: "log",
          threshold: "5",
          window_seconds: "600",
          bucket_seconds: "60",
          cooldown_seconds: "300",
          renotify_seconds: "21600",
          match: %{
            subject_prefix: "logs.syslog",
            severity_text: "ERROR"
          }
        }
      )
      |> render_submit()

      assert render(lv_alerts) =~ stateful_name
    end
  end

  describe "rule templates" do
    test "template management is available via presets modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=logs")

      refute has_element?(lv, "#zen_presets_modal")

      lv
      |> element("#open_zen_presets")
      |> render_click()

      assert has_element?(lv, "#zen_presets_modal")
      assert has_element?(lv, "#zen_template_form")
    end
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
