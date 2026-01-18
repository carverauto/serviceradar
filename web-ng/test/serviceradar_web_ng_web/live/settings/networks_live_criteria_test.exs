defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.CriteriaConversionTest do
  @moduledoc """
  Tests for targeting rules <-> criteria conversion functions.

  These tests verify that the SRQL builder correctly converts between
  UI rule format and database criteria format, ensuring data persists
  correctly through the save/edit cycle.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  describe "targeting rules round-trip persistence" do
    test "single CIDR rule persists through save/edit cycle", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      # Create sweep group with CIDR targeting via the form
      {:ok, lv, _html} = live(conn, ~p"/settings/networks/groups/new")

      # Fill in the form
      lv
      |> form("#sweep-group-form", %{
        "form" => %{
          "name" => "CIDR Test #{unique}",
          "interval" => "1h",
          "partition" => "default"
        }
      })
      |> render_change()

      # Add a targeting rule
      lv |> element("button", "Add Tag") |> render_click()

      # Update the rule to use ip field with in_cidr operator
      lv
      |> element("[phx-change='update_criteria_rule']")
      |> render_change(%{
        "rule_id" => "1",
        "field" => "ip",
        "operator" => "in_cidr",
        "value" => "10.0.0.0/8"
      })

      # Submit the form
      lv |> element("#sweep-group-form") |> render_submit()

      # Verify the group was created with correct criteria
      {:ok, [group]} =
        SweepGroup
        |> Ash.Query.filter(name == ^"CIDR Test #{unique}")
        |> Ash.read(scope: scope)

      assert group.target_criteria == %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}

      # Now edit the group and verify rules are loaded correctly
      {:ok, _lv, html} = live(conn, ~p"/settings/networks/groups/#{group.id}/edit")

      # The form should show the targeting rule
      assert html =~ "10.0.0.0/8"
    end

    test "tag has_any rule persists through save/edit cycle", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      # Create sweep group with criteria directly
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Tag Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"tags" => %{"has_any" => ["env=prod", "critical"]}}
        })
        |> Ash.create(scope: scope)

      # Verify criteria was saved
      assert group.target_criteria == %{"tags" => %{"has_any" => ["env=prod", "critical"]}}

      # Load the edit form and verify rules are displayed
      {:ok, _lv, html} = live(conn, ~p"/settings/networks/groups/#{group.id}/edit")

      # Should contain the tag values
      assert html =~ "env=prod" or html =~ "critical"
    end

    test "hostname contains rule persists through save/edit cycle", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Hostname Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"hostname" => %{"contains" => "server"}}
        })
        |> Ash.create(scope: scope)

      assert group.target_criteria == %{"hostname" => %{"contains" => "server"}}

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/groups/#{group.id}/edit")
      assert html =~ "server"
    end

    test "multiple criteria fields persist correctly", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      criteria = %{
        "ip" => %{"in_cidr" => "10.0.0.0/8"},
        "hostname" => %{"contains" => "prod"},
        "tags" => %{"has_any" => ["critical"]}
      }

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Multi Criteria Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: criteria
        })
        |> Ash.create(scope: scope)

      # Reload from database
      {:ok, reloaded} = Ash.get(SweepGroup, group.id, scope: scope)

      # All criteria should be preserved
      assert reloaded.target_criteria["ip"] == %{"in_cidr" => "10.0.0.0/8"}
      assert reloaded.target_criteria["hostname"] == %{"contains" => "prod"}
      assert reloaded.target_criteria["tags"] == %{"has_any" => ["critical"]}
    end

    test "empty criteria persists as empty map", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Empty Criteria Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{}
        })
        |> Ash.create(scope: scope)

      assert group.target_criteria == %{}

      {:ok, reloaded} = Ash.get(SweepGroup, group.id, scope: scope)
      assert reloaded.target_criteria == %{}
    end

    test "updating criteria replaces previous values", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      # Create with initial criteria
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Update Criteria Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}
        })
        |> Ash.create(scope: scope)

      # Update with new criteria
      {:ok, updated} =
        group
        |> Ash.Changeset.for_update(:update, %{
          target_criteria: %{"hostname" => %{"contains" => "new-server"}}
        })
        |> Ash.update(scope: scope)

      # Should have new criteria, not old
      assert updated.target_criteria == %{"hostname" => %{"contains" => "new-server"}}
      refute Map.has_key?(updated.target_criteria, "ip")
    end
  end

  describe "criteria validation" do
    test "invalid operator is rejected", %{scope: scope} do
      unique = System.unique_integer([:positive])

      result =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Invalid Op Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"hostname" => %{"invalid_operator" => "value"}}
        })
        |> Ash.create(scope: scope)

      assert {:error, _} = result
    end

    test "multiple operators per field is rejected", %{scope: scope} do
      unique = System.unique_integer([:positive])

      result =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Multi Op Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"hostname" => %{"eq" => "server1", "neq" => "server2"}}
        })
        |> Ash.create(scope: scope)

      assert {:error, _} = result
    end

    test "invalid CIDR format is rejected", %{scope: scope} do
      unique = System.unique_integer([:positive])

      result =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Invalid CIDR Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"ip" => %{"in_cidr" => "not-a-cidr"}}
        })
        |> Ash.create(scope: scope)

      assert {:error, _} = result
    end
  end

  describe "criteria with static_targets" do
    test "criteria and static_targets are both preserved", %{scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Combined Test #{unique}",
          partition: "default",
          interval: "1h",
          target_criteria: %{"ip" => %{"in_cidr" => "10.0.0.0/8"}},
          static_targets: ["192.168.1.0/24", "172.16.0.1"]
        })
        |> Ash.create(scope: scope)

      assert group.target_criteria == %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}
      assert "192.168.1.0/24" in group.static_targets
      assert "172.16.0.1" in group.static_targets
    end
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
