defmodule ServiceRadarWebNG.TimezonePreferenceTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope

  @moduletag :web_ng_shared_fixture_db

  test "updates only the acting user's validated display timezone" do
    user = viewer_user_fixture()
    other_user = user_fixture()
    admin = admin_user_fixture()
    own_scope = Scope.for_user(user)
    admin_scope = Scope.for_user(admin)

    assert user.timezone == "Etc/UTC"

    assert {:ok, updated} =
             User.update_timezone_preference(user, %{timezone: " America/Chicago "}, scope: own_scope)

    assert updated.timezone == "America/Chicago"

    assert {:ok, utc} = User.update_timezone_preference(updated, %{timezone: "Z"}, scope: own_scope)
    assert utc.timezone == "Etc/UTC"

    assert {:error, %Invalid{}} =
             User.update_timezone_preference(utc, %{timezone: "Etc/GMT+5"}, scope: own_scope)

    assert fresh_user(utc.id).timezone == "Etc/UTC"

    catalog_down = fn _sql, _params -> {:error, :catalog_unavailable} end

    catalog_failure_changeset =
      utc
      |> Ash.Changeset.new()
      |> put_time_zone_query(catalog_down)
      |> Ash.Changeset.for_update(:update_timezone_preference, %{timezone: "America/Chicago"},
        actor: user,
        authorize?: true
      )

    assert {:error, %Invalid{}} = Ash.update(catalog_failure_changeset)

    assert fresh_user(utc.id).timezone == "Etc/UTC"

    assert {:error, %Forbidden{}} =
             User.update_timezone_preference(other_user, %{timezone: "America/Chicago"}, scope: own_scope)

    assert fresh_user(other_user.id).timezone == "Etc/UTC"

    assert {:error, %Forbidden{}} =
             User.update_timezone_preference(other_user, %{timezone: "America/Chicago"}, scope: admin_scope)

    assert fresh_user(other_user.id).timezone == "Etc/UTC"
  end

  defp fresh_user(id) do
    assert {:ok, user} = User.get_by_id(id, actor: system_actor())
    user
  end

  defp put_time_zone_query(changeset, query) do
    private = changeset.context |> Map.get(:private, %{}) |> Map.put(:time_zone_query, query)
    %{changeset | context: Map.put(changeset.context, :private, private)}
  end
end
