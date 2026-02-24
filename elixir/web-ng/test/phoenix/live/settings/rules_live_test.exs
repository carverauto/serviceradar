defmodule ServiceRadarWebNGWeb.Settings.RulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)
    }
  end

  describe "log normalization rules" do
    test "creates and deletes a Zen rule", %{conn: conn, scope: scope} do
      {:ok, editor_lv, _html} = live(conn, ~p"/settings/rules/zen/new")
      unique = System.unique_integer([:positive])
      rule_name = "syslog-clean-#{unique}"

      editor_lv
      |> form("#zen_rule_form",
        zen_rule: %{
          "name" => rule_name,
          "subject" => "logs.syslog",
          "template" => "passthrough",
          "stream_name" => "events",
          "agent_id" => "default-agent",
          "enabled" => "true",
          "order" => "10"
        }
      )
      |> render_submit()

      assert render(editor_lv) =~ "Rule saved successfully"

      rules = unwrap_page(Ash.read(ZenRule, scope: scope))
      rule = Enum.find(rules, &(&1.name == rule_name))

      assert rule
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=logs")
      assert render(lv) =~ rule_name

      lv
      |> element("button[phx-click='delete_zen'][phx-value-id='#{rule.id}']")
      |> render_click()

      rules_after = unwrap_page(Ash.read(ZenRule, scope: scope))
      refute Enum.any?(rules_after, &(&1.id == rule.id))
    end
  end

  describe "event and alert rules" do
    test "renders events and alerts tabs", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/rules?tab=events")
      assert html =~ "Event Rules"

      {:ok, _lv, html} = live(conn, ~p"/settings/rules?tab=alerts")
      assert html =~ "Alert Rules"
    end
  end

  describe "rule templates" do
    test "log normalization tab links to the Zen rule editor", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=logs")

      assert has_element?(lv, "a", "New Rule")
      assert render(lv) =~ "/settings/rules/zen/new"
    end
  end

  describe "promotion rule builder" do
    test "opens rule builder modal when clicking New Rule", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")

      # Click the New Rule button
      lv
      |> element("button[phx-click=new_promotion_rule]", "New Log Rule")
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
      |> element("button[phx-click=new_promotion_rule]", "New Log Rule")
      |> render_click()

      # Enable the condition so the input is no longer disabled (LiveViewTest won't fill disabled inputs)
      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => rule_name,
          "body_contains_enabled" => "true"
        }
      })
      |> render_change()

      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => rule_name,
          "body_contains_enabled" => "true",
          "severity_enabled" => "true"
        }
      })
      |> render_change()

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
      rules = unwrap_page(Ash.read(EventRule, scope: scope))
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
        Ash.create(
          EventRule,
          %{
            name: rule_name,
            enabled: true,
            priority: 100,
            match: %{"body_contains" => "original error"}
          },
          action: :create,
          scope: scope
        )

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
      updated_rule =
        EventRule
        |> Ash.read!(scope: scope)
        |> case do
          %Ash.Page.Keyset{results: results} -> results
          results when is_list(results) -> results
          _ -> []
        end
        |> Enum.find(&(&1.id == rule.id))

      assert updated_rule
      assert updated_rule.match["body_contains"] == "updated error"
    end

    test "toggles promotion rule enabled status", %{conn: conn, scope: scope} do
      # Create a rule first
      unique = System.unique_integer([:positive])

      {:ok, rule} =
        Ash.create(
          EventRule,
          %{
            name: "toggle-test-#{unique}",
            enabled: true,
            priority: 100,
            match: %{"body_contains" => "test"}
          },
          action: :create,
          scope: scope
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/rules?tab=events")

      # Toggle the rule off
      lv
      |> element("input[phx-click='toggle_promotion'][phx-value-id='#{rule.id}']")
      |> render_click()

      # Verify rule was disabled
      updated_rule =
        EventRule
        |> Ash.read!(scope: scope)
        |> case do
          %Ash.Page.Keyset{results: results} -> results
          results when is_list(results) -> results
          _ -> []
        end
        |> Enum.find(&(&1.id == rule.id))

      assert updated_rule
      refute updated_rule.enabled
    end

    test "shows match conditions summary for rules", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, _rule} =
        Ash.create(
          EventRule,
          %{
            name: "summary-test-#{unique}",
            enabled: true,
            priority: 100,
            match: %{
              "body_contains" => "error message",
              "severity_text" => "error",
              "service_name" => "test-service"
            }
          },
          action: :create,
          scope: scope
        )

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
      |> element("button[phx-click=new_promotion_rule]", "New Log Rule")
      |> render_click()

      # Try to submit without enabling any conditions
      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => "invalid-rule-#{unique}"
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
