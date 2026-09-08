defmodule ServiceRadarWebNGWeb.DashboardPackageLive.ShowTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Dashboards

  test "unauthorized viewer sees the same not-found as an unknown slug", %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    viewer = viewer_user()
    {_package, instance} = private_instance!(admin)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/dashboards/#{instance.route_slug}")

    html = render_async(view, 5_000)
    assert html =~ "Dashboard package unavailable"
    refute html =~ instance.name
    refute html =~ "stream_token"
    refute html =~ "Share"

    {:ok, missing_view, _missing_html} =
      conn
      |> recycle()
      |> log_in_user(viewer)
      |> live(~p"/dashboards/does-not-exist-#{System.unique_integer([:positive])}")

    missing_html = render_async(missing_view, 5_000)
    assert missing_html =~ "Dashboard package unavailable"
  end

  test "hub omits a private instance owned by someone else", %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    viewer = viewer_user()
    {_package, instance} = private_instance!(admin)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/dashboards")

    html = render_async(view, 5_000)
    refute html =~ instance.name
    refute html =~ instance.route_slug
  end

  test "share control lives in the operations topbar instead of over the dashboard", %{conn: conn} do
    owner = AshTestHelpers.admin_user_fixture()
    {_package, instance} = public_instance!(owner)

    {:ok, view, html} =
      conn
      |> log_in_user(owner)
      |> live(~p"/dashboards/#{instance.route_slug}")

    html = html <> render_async(view, 5_000)

    refute html =~ "absolute right-4 top-4 z-20"
    assert has_element?(view, "#ops-topbar #dashboard-package-share-button", "Share")
    refute has_element?(view, "#dashboard-package-share-modal")

    view
    |> element("#dashboard-package-share-button")
    |> render_click()

    assert has_element?(view, "#dashboard-package-share-modal", "Share dashboard")
    assert has_element?(view, "#dashboard-package-share-modal", "Visibility")
    assert has_element?(view, "#ops-topbar #dashboard-package-share-button")
  end

  defp viewer_user do
    AshTestHelpers.user_fixture()
    |> Ash.Changeset.for_update(:update_role, %{role: :viewer}, actor: AshTestHelpers.system_actor())
    |> Ash.update!()
  end

  defp private_instance!(owner), do: enabled_instance!(owner, :private, "Secret")

  defp public_instance!(owner), do: enabled_instance!(owner, :public, "Public")

  defp enabled_instance!(owner, visibility, name_prefix) do
    suffix = System.unique_integer([:positive])

    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: "com.test.show.#{suffix}",
        name: "#{name_prefix} Package #{suffix}",
        version: "0.1.0",
        manifest: %{},
        renderer: %{
          "kind" => "browser_module",
          "interface_version" => "dashboard-browser-module-v1",
          "artifact" => "renderer.js",
          "sha256" => String.duplicate("a", 64)
        },
        data_frames: [],
        capabilities: [],
        settings_schema: %{},
        wasm_object_key: "dashboards/test/show-#{suffix}.js",
        content_hash: String.duplicate("a", 64),
        verification_status: "verified",
        status: :enabled
      })
      |> Ash.create!(actor: AshTestHelpers.system_actor())

    {:ok, instance} =
      Dashboards.create_instance(
        package,
        %{
          name: "#{name_prefix} Instance #{suffix}",
          route_slug: "#{String.downcase(name_prefix)}-#{suffix}",
          enabled: true,
          visibility: visibility,
          owner_id: owner.id
        },
        actor: AshTestHelpers.system_actor()
      )

    {package, instance}
  end
end
