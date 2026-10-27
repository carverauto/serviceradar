defmodule ServiceRadarWebNGWeb.CameraRecordingsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.CameraComponents

  @moduletag :web_ng_shared_fixture_db

  setup do
    actor = AshTestHelpers.system_actor()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:archive-page-#{Ecto.UUID.generate()}",
          vendor: "synthetic",
          vendor_camera_id: Ecto.UUID.generate(),
          display_name: "Example gate camera"
        },
        actor: actor
      )

    %{source: source, actor: actor}
  end

  test "recording-only access opens an empty archive without a live relay and rechecks paging authority", %{
    conn: conn,
    source: source,
    actor: actor
  } do
    permissions = ["devices.view", "devices.cameras.recordings.view"]
    {user, profile} = user_with_permissions(permissions, actor)
    scope = Scope.for_user(user)

    navigation =
      (&CameraComponents.camera_streams_section/1)
      |> render_component(
        camera_sources: [%{source | stream_profiles: []}],
        can_view_recordings: RBAC.can?(scope, "devices.view") && RBAC.can?(scope, "devices.cameras.recordings.view")
      )
      |> LazyHTML.from_fragment()

    assert navigation |> LazyHTML.query("#camera-recordings-link-#{source.id}") |> LazyHTML.attribute("href") ==
             ["/cameras/#{source.id}/recordings"]

    assert navigation |> LazyHTML.query("[phx-click='open_camera_relay']") |> LazyHTML.attribute("phx-click") == []
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/cameras/#{source.id}/recordings")
    assert has_element?(view, "#camera-recordings-empty")
    refute has_element?(view, "#camera-archive-player")
    refute has_element?(view, "#next-recordings")
    assert has_element?(view, "a[href='/devices/#{URI.encode_www_form(source.device_uid)}']")

    assert %{rows: [[0]]} =
             ServiceRadarWebNG.Repo.query!(
               "SELECT count(*) FROM platform.camera_relay_sessions WHERE camera_source_id = $1",
               [Ecto.UUID.dump!(source.id)]
             )

    profile
    |> Ash.Changeset.for_update(:update, %{permissions: ["devices.view"]},
      actor: actor,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.update!()

    RBAC.Cache.put(user.id, MapSet.new(permissions))

    render_click(view, "next_recordings")
    assert has_element?(view, "#camera-recordings-error", "permission")
    refute has_element?(view, "#camera-archive-player")
    view |> element("#refresh-recordings") |> render_click()
    assert has_element?(view, "#camera-recordings-error", "permission")
  end

  test "live permission or recording permission alone cannot mount an archive", %{
    conn: conn,
    source: source,
    actor: actor
  } do
    for permissions <- [["devices.view", "devices.cameras.view"], ["devices.cameras.recordings.view"]] do
      {user, _profile} = user_with_permissions(permissions, actor)
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/cameras/#{source.id}/recordings")
      assert has_element?(view, "#camera-recordings-error", "permission")
      refute has_element?(view, "#camera-archive-player")
      refute has_element?(view, "#camera-recordings-empty")
    end
  end

  defp user_with_permissions(permissions, actor) do
    user = AshTestHelpers.user_fixture()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Synthetic archive page #{Ecto.UUID.generate()}", permissions: permissions},
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    user =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: actor)
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(user.id, MapSet.new(permissions))
    on_exit(fn -> RBAC.Cache.invalidate(user.id) end)
    {user, profile}
  end
end
