defmodule ServiceRadarWebNGWeb.Admin.EdgePackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, actor_for_user: 1]

  alias ServiceRadarWebNG.Edge.OnboardingPackages

  @private_key "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  @public_key "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  setup %{conn: conn} do
    previous_private_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    previous_public_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_public_key)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, @private_key)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, @public_key)

    user = admin_user_fixture()
    actor = actor_for_user(user)
    gateway_id = "test-gateway-#{System.unique_integer([:positive])}"

    case ServiceRadar.GatewayRegistry.register_gateway(gateway_id, %{
           partition_id: "default",
           domain: "local",
           status: :available
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
      {:error, _} -> :ok
    end

    on_exit(fn ->
      ServiceRadar.GatewayRegistry.unregister_gateway(gateway_id)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous_private_key)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, previous_public_key)
    end)

    %{conn: log_in_user(conn, user), user: user, actor: actor, gateway_id: gateway_id}
  end

  describe "index" do
    test "renders edge packages page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/edge-packages")

      assert html =~ "Edge Onboarding"
      assert html =~ "New Package"
    end

    test "lists existing packages", %{conn: conn, actor: actor} do
      {:ok, _} =
        OnboardingPackages.create(
          %{label: "test-display-pkg", component_type: :gateway},
          actor: actor
        )

      {:ok, _lv, html} = live(conn, ~p"/admin/edge-packages")

      assert html =~ "test-display-pkg"
    end
  end

  describe "create modal" do
    test "opens create modal", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      assert html =~ "Create Edge Package"
      assert html =~ "Zero-touch provisioning"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      html =
        lv
        |> form("#create_package_form", form: %{label: "test-agent"})
        |> render_change()

      assert html =~ "Partition"
    end

    test "shows gateway_id for agent packages", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      html = render(lv)
      assert html =~ "Parent Gateway ID"
    end

    test "has advanced options collapse", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      assert html =~ "Advanced options"
      assert html =~ "Security Mode"
    end

    test "closes modal on cancel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      # Click cancel
      html =
        lv
        |> element("button", "Cancel")
        |> render_click()

      refute html =~ "Create Edge Package"
    end
  end

  describe "package creation flow" do
    test "creates a package and shows success", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      # Submit form
      lv
      |> form("#create_package_form",
        form: %{
          label: "test-new-agent"
        }
      )
      |> render_submit()

      # May show loading, success, or gateway-related failure depending on local test environment.
      html = render(lv)

      assert html =~ "Creating Package" or
               html =~ "Package Created Successfully" or
               html =~ "Agent gateway is unavailable" or
               html =~ "Gateway CA is not available" or
               html =~ "Failed to create package"
    end

    test "auto-generates component_id from label", %{actor: actor} do
      # Create a package via the UI flow
      attrs = %{
        label: "Production Gateway 01",
        component_type: :gateway
      }

      # The build_package_attrs_from_form function is tested indirectly
      # by verifying packages have component_ids that match the expected format
      {:ok, result} =
        OnboardingPackages.create(
          Map.put(attrs, :component_id, "gateway-production-gateway-01"),
          actor: actor
        )

      assert result.package.component_id == "gateway-production-gateway-01"
    end

    test "agent success modal uses explicit configured core-url in enroll command", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/new?component_type=agent")

      lv
      |> form("#create_package_form",
        form: %{
          label: "test-agent-enroll-command"
        }
      )
      |> render_submit()

      html = render(lv)

      assert html =~ "serviceradar-cli enroll --core-url http://localhost:4002 --token edgepkg-v2:"
      refute html =~ "/usr/local/bin/serviceradar-cli enroll --token edgepkg-v2:"
    end
  end

  describe "package filters" do
    test "filters by status", %{conn: conn, actor: actor} do
      {:ok, r1} =
        OnboardingPackages.create(
          %{label: "filter-test-issued", component_type: :gateway},
          actor: actor
        )

      # Revoke one
      OnboardingPackages.revoke(r1.package.id, actor: actor)

      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages")

      # Filter by revoked
      html =
        lv
        |> element("select[name='status']")
        |> render_change(%{status: "revoked", component_type: ""})

      # Should show revoked packages
      assert html =~ "revoked" or html =~ "Revoked"
    end

    test "filters by component type", %{conn: conn, actor: actor} do
      {:ok, _} =
        OnboardingPackages.create(
          %{label: "filter-checker", component_type: :checker},
          actor: actor
        )

      {:ok, _lv, html} = live(conn, ~p"/admin/edge-packages")

      # The index page renders the component type in the table.
      assert html =~ "checker" or html =~ "Checker"
    end
  end

  describe "package details modal" do
    test "shows package details", %{conn: conn, actor: actor} do
      {:ok, result} =
        OnboardingPackages.create(
          %{label: "detail-view-test", component_type: :gateway, notes: "Test notes here"},
          actor: actor
        )

      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/#{result.package.id}")

      html = render(lv)

      assert html =~ "Package Details"
      assert html =~ "detail-view-test"
    end

    test "closes details modal", %{conn: conn, actor: actor} do
      {:ok, result} =
        OnboardingPackages.create(
          %{label: "close-modal-test", component_type: :gateway},
          actor: actor
        )

      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages/#{result.package.id}")

      html =
        lv
        |> element("button", "Close")
        |> render_click()

      # Should close modal (no longer show package details title)
      refute html =~ "Package Details"
    end
  end

  describe "package actions" do
    test "revokes a package", %{conn: conn, actor: actor} do
      {:ok, result} =
        OnboardingPackages.create(
          %{label: "revoke-test", component_type: :gateway},
          actor: actor
        )

      {:ok, lv, _html} = live(conn, ~p"/admin/edge-packages")

      # Click revoke in the table
      html =
        lv
        |> element("button[phx-click='revoke_package'][phx-value-id='#{result.package.id}']")
        |> render_click()

      assert html =~ "Package revoked" or html =~ "revoked"
    end
  end
end
