defmodule ServiceRadarWebNGWeb.Settings.AnsibleLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "creates controller from raw AWX token by storing a network credential secret", %{
    conn: conn
  } do
    controller_name = "AWX Controller #{System.unique_integer([:positive])}"
    raw_token = "awx-test-token-#{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    lv
    |> element("button", "+ Add controller")
    |> render_click()

    html =
      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "awx_api_token" => raw_token,
          "credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600",
          "run_pulse_interval_ms" => "2000"
        }
      })
      |> render_submit()

    refute html =~ raw_token

    controller = controller_by_name!(controller_name)
    assert controller.agent_id == "k8s-agent"
    assert controller.base_url == "http://awx-service.awx.svc.cluster.local"
    assert controller.credential_secret_id

    secret =
      NetworkCredentialSecret.get_by_id!(controller.credential_secret_id,
        actor: system_actor()
      )

    assert secret.provider == "awx"
    assert secret.credential_kind == :api_token
    assert secret.metadata["source"] == "ansible_controller_form"
    refute inspect(secret) =~ raw_token
  end

  test "guides raw tokens away from the existing secret UUID field", %{conn: conn} do
    controller_name = "AWX Invalid UUID #{System.unique_integer([:positive])}"
    raw_token_like_value = "awx-token-in-wrong-field"

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    lv
    |> element("button", "+ Add controller")
    |> render_click()

    html =
      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "awx_api_token" => "",
          "credential_secret_id" => raw_token_like_value,
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600",
          "run_pulse_interval_ms" => "2000"
        }
      })
      |> render_submit()

    assert html =~ "Existing credential secret ID must be a UUID"
    refute html =~ raw_token_like_value
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp controller_by_name!(name) do
    Controller
    |> Ash.read!(action: :read, actor: system_actor())
    |> Enum.find(&(&1.name == name))
  end
end
