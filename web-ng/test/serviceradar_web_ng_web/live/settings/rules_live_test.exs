defmodule ServiceRadarWebNGWeb.Settings.RulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.LogPromotionRule

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

  describe "promotion rule builder" do
    test "opens rule builder modal when clicking New Rule", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")

      # Click the New Rule button
      lv
      |> element("button", "New Rule")
      |> render_click()

      # Modal should be visible
      assert has_element?(lv, "#rule_builder_modal")
      assert has_element?(lv, "h3", "Create Event Rule")
    end

    test "creates promotion rule via rule builder", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")
      unique = System.unique_integer([:positive])
      rule_name = "test-rule-#{unique}"

      # Open the rule builder
      lv
      |> element("button", "New Rule")
      |> render_click()

      # Fill in the form
      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => rule_name,
          "body_contains_enabled" => "true",
          "body_contains" => "test error",
          "severity_enabled" => "true",
          "severity_text" => "error"
        }
      })
      |> render_submit()

      # Modal should close and rule should appear
      refute has_element?(lv, "#rule_builder_modal")
      assert render(lv) =~ rule_name

      # Verify rule was created
      rules = unwrap_page(Ash.read(LogPromotionRule, scope: scope))
      rule = Enum.find(rules, &(&1.name == rule_name))
      assert rule
      assert rule.match["body_contains"] == "test error"
      assert rule.match["severity_text"] == "error"
    end

    test "edits existing promotion rule", %{conn: conn, scope: scope} do
      # Create a rule first
      unique = System.unique_integer([:positive])
      rule_name = "edit-test-#{unique}"

      {:ok, rule} =
        Ash.create(LogPromotionRule, %{
          name: rule_name,
          enabled: true,
          priority: 100,
          match: %{"body_contains" => "original error"}
        }, scope: scope)

      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")

      # Click edit button for the rule
      lv
      |> element("button[phx-click='edit_promotion_rule'][phx-value-id='#{rule.id}']")
      |> render_click()

      # Modal should show with existing values
      assert has_element?(lv, "#rule_builder_modal")
      assert has_element?(lv, "h3", "Edit Event Rule")

      # Update the rule
      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => rule_name,
          "body_contains_enabled" => "true",
          "body_contains" => "updated error"
        }
      })
      |> render_submit()

      # Verify rule was updated
      {:ok, updated_rule} = Ash.get(LogPromotionRule, rule.id, scope: scope)
      assert updated_rule.match["body_contains"] == "updated error"
    end

    test "toggles promotion rule enabled status", %{conn: conn, scope: scope} do
      # Create a rule first
      unique = System.unique_integer([:positive])

      {:ok, rule} =
        Ash.create(LogPromotionRule, %{
          name: "toggle-test-#{unique}",
          enabled: true,
          priority: 100,
          match: %{"body_contains" => "test"}
        }, scope: scope)

      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")

      # Toggle the rule off
      lv
      |> element("input[phx-click='toggle_promotion'][phx-value-id='#{rule.id}']")
      |> render_click()

      # Verify rule was disabled
      {:ok, updated_rule} = Ash.get(LogPromotionRule, rule.id, scope: scope)
      refute updated_rule.enabled
    end

    test "shows match conditions summary for rules", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, _rule} =
        Ash.create(LogPromotionRule, %{
          name: "summary-test-#{unique}",
          enabled: true,
          priority: 100,
          match: %{
            "body_contains" => "error message",
            "severity_text" => "error",
            "service_name" => "test-service"
          }
        }, scope: scope)

      {:ok, _lv, html} = live(conn, ~p"/settings/rules?tab=events")

      # Should show match conditions in the UI
      assert html =~ "body: error message"
      assert html =~ "severity: error"
      assert html =~ "service: test-service"
    end

    test "validates at least one condition is required", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")
      unique = System.unique_integer([:positive])

      # Open the rule builder
      lv
      |> element("button", "New Rule")
      |> render_click()

      # Try to submit without enabling any conditions
      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => "invalid-rule-#{unique}",
          "body_contains_enabled" => "false",
          "severity_enabled" => "false",
          "service_name_enabled" => "false",
          "attribute_enabled" => "false"
        }
      })
      |> render_submit()

      # Should show validation error
      assert has_element?(lv, ".alert-error")
      assert render(lv) =~ "At least one match condition must be enabled"
    end
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
