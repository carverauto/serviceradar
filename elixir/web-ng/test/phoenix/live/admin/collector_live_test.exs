defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  setup %{conn: conn} do
    previous_nats_url = Application.get_env(:serviceradar, :nats_url)
    Application.put_env(:serviceradar, :nats_url, "nats://serviceradar-nats:4222")

    on_exit(fn ->
      Application.put_env(:serviceradar, :nats_url, previous_nats_url)
    end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  describe "falcosidekick creation flow" do
    test "shows bundle deployment instructions instead of generic CLI enrollment", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/collectors")

      lv
      |> element("button", "New Collector")
      |> render_click()

      html =
        lv
        |> form("form[phx-submit='create_package']", %{
          "collector_type" => "falcosidekick",
          "site" => "demo",
          "hostname" => "falco-demo",
          "edge_site_id" => ""
        })
        |> render_submit()

      assert html =~ "Collector Created"
      assert html =~ "Step 1: Download and deploy the bundle"
      assert html =~ "Step 2: Run the bundle command"
      assert html =~ "serviceradar-runtime-certs"
      assert html =~ "/api/collectors/"
      assert html =~ "./deploy.sh"

      refute html =~ "sudo apt install serviceradar-falcosidekick"
      refute html =~ "/usr/local/bin/serviceradar-cli enroll --token"
    end
  end

  describe "collector capability gating" do
    test "hides collector creation UI when onboarding is disabled", %{conn: conn} do
      previous_capabilities = Application.get_env(:serviceradar_web_ng, :runtime_capabilities)

      Application.put_env(:serviceradar_web_ng, :runtime_capabilities,
        configured?: true,
        enabled: []
      )

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, :runtime_capabilities, previous_capabilities)
      end)

      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "Collector onboarding is disabled for this deployment."
      refute html =~ "New Collector"
      refute html =~ "Data Collectors"
    end
  end
end
