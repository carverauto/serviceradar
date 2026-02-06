defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.CriteriaConversionTest do
  @moduledoc """
  Tests SRQL targeting persistence for sweep groups.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  describe "SRQL targeting persistence" do
    test "target_query persists through save/edit cycle", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])
      target_name = "SRQL Test #{unique}"

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/groups/new")

      lv
      |> form("#sweep-group-form", %{
        "form" => %{
          "name" => target_name,
          "interval" => "1h",
          "partition" => "default",
          "target_query" => "in:devices ip:10.0.0.0/8"
        }
      })
      |> render_change()

      lv |> element("#sweep-group-form") |> render_submit()

      {:ok, [group]} =
        SweepGroup
        |> Ash.Query.filter(name == ^target_name)
        |> Ash.read(scope: scope)

      assert group.target_query == "in:devices ip:10.0.0.0/8"

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/groups/#{group.id}/edit")
      assert html =~ "in:devices ip:10.0.0.0/8"
    end

    test "target_query is normalized with in:devices prefix", %{scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Normalize Test #{unique}",
          partition: "default",
          interval: "1h",
          target_query: "hostname:%prod%"
        })
        |> Ash.create(scope: scope)

      assert group.target_query == "in:devices hostname:%prod%"
    end

    test "empty target_query is stored as nil", %{scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(:create, %{
          name: "Empty Query #{unique}",
          partition: "default",
          interval: "1h",
          target_query: ""
        })
        |> Ash.create(scope: scope)

      assert is_nil(group.target_query)
    end
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
