defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  @private_key "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  @public_key "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  setup %{conn: conn} do
    previous_web_nats_url = Application.get_env(:serviceradar_web_ng, :nats_url)
    previous_core_nats_url = Application.get_env(:serviceradar, :nats_url)
    previous_private_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    previous_public_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_public_key)
    Application.put_env(:serviceradar_web_ng, :nats_url, "tls://serviceradar-nats:4222")
    Application.delete_env(:serviceradar, :nats_url)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, @private_key)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, @public_key)

    on_exit(fn ->
      restore_env(:serviceradar_web_ng, :nats_url, previous_web_nats_url)
      restore_env(:serviceradar, :nats_url, previous_core_nats_url)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous_private_key)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, previous_public_key)
    end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  describe "nats deployment status" do
    test "reads the web-ng NATS URL instead of spinning on provisioning", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Ready"
      assert html =~ "tls://serviceradar-nats:4222"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end

    test "says NATS is not configured when no URL is set", %{conn: conn} do
      Application.delete_env(:serviceradar_web_ng, :nats_url)
      Application.delete_env(:serviceradar, :nats_url)

      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Not Configured"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end
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
      assert html =~ "http://localhost:4002/api/collectors/"
      assert html =~ "./deploy.sh"

      refute html =~ "sudo apt install serviceradar-falcosidekick"
      refute html =~ "/usr/local/bin/srctl enroll --token"
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
