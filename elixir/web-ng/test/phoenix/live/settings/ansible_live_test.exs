defmodule ServiceRadarWebNGWeb.Settings.AnsibleLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "creates a sync-only controller from a raw AWX token without elevating other purposes", %{
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
          "sync_awx_api_token" => raw_token,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "execution_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
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
    assert controller.sync_credential_secret_id
    assert controller.credential_secret_id == controller.sync_credential_secret_id
    assert controller.execution_credential_secret_id == nil
    assert controller.callback_credential_secret_id == nil

    secret =
      NetworkCredentialSecret.get_by_id!(controller.sync_credential_secret_id,
        actor: system_actor()
      )

    assert secret.provider == "awx"
    assert secret.credential_kind == :api_token
    assert secret.metadata["source"] == "ansible_controller_form"
    assert secret.metadata["credential_purpose"] == "sync"
    refute inspect(secret) =~ raw_token
  end

  test "links a DB-backed AWX secret selected from the credential dropdown", %{
    conn: conn,
    scope: scope
  } do
    controller_name = "AWX From Secret #{System.unique_integer([:positive])}"
    sync_secret = awx_secret_fixture(scope, "sync")
    execution_secret = awx_secret_fixture(scope, "execution")

    {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

    form_html =
      lv
      |> element("button", "+ Add controller")
      |> render_click()

    # The DB-backed AWX secret is offered by name in a dropdown; no UUID typing.
    assert form_html =~ sync_secret.name
    assert form_html =~ execution_secret.name
    assert form_html =~ ~s(name="controller[sync_credential_secret_id]")
    assert form_html =~ ~s(name="controller[execution_credential_secret_id]")
    assert form_html =~ ~s(name="controller[callback_credential_secret_id]")
    assert form_html =~ "Existing sync credential secret"

    lv
    |> form("#ansible-controller-form", %{
      "controller" => %{
        "name" => controller_name,
        "agent_id" => "k8s-agent",
        "description" => "",
        "base_url" => "http://awx-service.awx.svc.cluster.local",
        "sync_awx_api_token" => "",
        "credential_secret_id" => "",
        "sync_credential_secret_id" => sync_secret.id,
        "execution_credential_secret_id" => execution_secret.id,
        "callback_credential_secret_id" => execution_secret.id,
        "inventory_sync_interval_seconds" => "300",
        "catalog_sync_interval_seconds" => "600",
        "run_pulse_interval_ms" => "2000"
      }
    })
    |> render_submit()

    controller = controller_by_name!(controller_name)
    assert to_string(controller.credential_secret_id) == to_string(sync_secret.id)
    assert to_string(controller.sync_credential_secret_id) == to_string(sync_secret.id)

    assert to_string(controller.execution_credential_secret_id) ==
             to_string(execution_secret.id)

    assert to_string(controller.callback_credential_secret_id) ==
             to_string(execution_secret.id)
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

  defp awx_secret_fixture(_scope, purpose) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "AWX #{purpose} token #{System.unique_integer([:positive])}",
          provider: "awx",
          credential_kind: :api_token,
          public_fingerprint: "sha256:test",
          secret_payload: "awx-bearer-token",
          metadata: %{
            "auth_method" => "bearer_token",
            "source" => "credential_rules_form",
            "credential_purpose" => purpose
          }
        },
        actor: system_actor()
      )
      |> Ash.create(actor: system_actor())

    secret
  end
end
