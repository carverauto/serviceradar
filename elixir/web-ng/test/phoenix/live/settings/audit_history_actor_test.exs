defmodule ServiceRadarWebNGWeb.Settings.AuditHistoryActorTest do
  @moduledoc """
  Settings → Audit → History renders the recorded actor UUID as the
  user's login email linked to the user detail page (issues #341, #343),
  falling back to the raw recorded value when the actor is not a known
  user.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :integration

  @profile_permissions MapSet.new([
                         "visibility_profiles:read",
                         "visibility_profiles:write",
                         "visibility_profiles:delete"
                       ])

  setup %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "resolves a bare actor UUID to a linked login email", %{
    conn: conn,
    admin: admin
  } do
    # The API path stamps only the actor id (no email) into the version
    # row, which is exactly the bare-UUID case from the bug report.
    create_actor_config(%{id: admin.id})

    {:ok, _view, html} = live(conn, ~p"/settings/audit/history")

    assert html =~ to_string(admin.email)
    assert html =~ ~s(href="/settings/auth/users/#{admin.id}")
  end

  test "falls back to the raw UUID for an unknown actor", %{conn: conn} do
    unknown_id = Ash.UUID.generate()
    create_actor_config(%{id: unknown_id})

    {:ok, _view, html} = live(conn, ~p"/settings/audit/history")

    assert html =~ unknown_id
  end

  defp create_actor_config(%{id: id}) do
    unique = System.unique_integer([:positive])

    actor = %{id: id, role: :admin, permissions: @profile_permissions}

    VisibilityProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Audit actor #{unique}",
        partition_id: "audit-actor-partition",
        target_query: "in:devices type:0",
        capture_interfaces: ["eth0"],
        enabled: true
      },
      actor: actor
    )
    |> Ash.create!()
  end
end
