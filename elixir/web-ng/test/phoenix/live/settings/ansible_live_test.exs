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

  describe "execution and callback token entry" do
    # Sync already accepted a pasted token; execution and callback could only be
    # set by pasting a secret UUID. That is the copy-a-UUID step this change
    # removes, and the likely reason the two elevated purposes were routinely
    # left unset while sync was configured -- they were the harder ones to fill
    # in, and they are the ones that launch jobs and mint ephemeral credentials.

    test "each purpose gets its own secret, and none is shared", %{conn: conn} do
      controller_name = "AWX Three #{System.unique_integer([:positive])}"
      sync_token = "sync-tok-#{System.unique_integer([:positive])}"
      exec_token = "exec-tok-#{System.unique_integer([:positive])}"
      cb_token = "cb-tok-#{System.unique_integer([:positive])}"

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      html =
        lv
        |> form("#ansible-controller-form", %{
          "controller" => %{
            "name" => controller_name,
            "agent_id" => "k8s-agent",
            "description" => "",
            "base_url" => "http://awx-service.awx.svc.cluster.local",
            "sync_awx_api_token" => sync_token,
            "execution_awx_api_token" => exec_token,
            "callback_awx_api_token" => cb_token,
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

      for token <- [sync_token, exec_token, cb_token] do
        refute html =~ token
      end

      controller = controller_by_name!(controller_name)

      ids = [
        controller.sync_credential_secret_id,
        controller.execution_credential_secret_id,
        controller.callback_credential_secret_id
      ]

      assert Enum.all?(ids, &is_binary/1)

      # The privilege ceilings only mean something if the three are distinct
      # secrets. Reusing one would silently give sync the ability to launch jobs
      # and delete credentials.
      assert Enum.uniq(ids) == ids

      for {id, purpose} <- Enum.zip(ids, ["sync", "execution", "callback"]) do
        secret = NetworkCredentialSecret.get_by_id!(id, actor: system_actor())
        assert secret.provider == "awx"
        assert secret.credential_kind == :api_token
        assert secret.metadata["credential_purpose"] == purpose
        assert secret.metadata["source"] == "ansible_controller_form"
        refute inspect(secret) =~ sync_token
        refute inspect(secret) =~ exec_token
        refute inspect(secret) =~ cb_token
      end
    end

    test "a pasted token wins over a selected secret for the same purpose", %{conn: conn} do
      # Same precedence sync already uses: you only paste when you mean to set or
      # rotate, and the select still holds whatever was bound before.
      controller_name = "AWX Precedence #{System.unique_integer([:positive])}"
      exec_token = "exec-wins-#{System.unique_integer([:positive])}"

      {:ok, existing} =
        NetworkCredentialSecret.create_secret(
          %{
            name: "Preexisting exec #{System.unique_integer([:positive])}",
            provider: "awx",
            credential_kind: :api_token,
            secret_payload: "should-not-be-used"
          },
          actor: system_actor()
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "sync-#{System.unique_integer([:positive])}",
          "execution_awx_api_token" => exec_token,
          "execution_credential_secret_id" => existing.id,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600",
          "run_pulse_interval_ms" => "2000"
        }
      })
      |> render_submit()

      controller = controller_by_name!(controller_name)

      refute controller.execution_credential_secret_id == existing.id
      assert controller.execution_credential_secret_id
    end

    test "blank token fields leave the selected secrets alone", %{conn: conn} do
      # Editing a controller without rotating anything must not mint new secrets.
      controller_name = "AWX Blank #{System.unique_integer([:positive])}"

      {:ok, exec_secret} =
        NetworkCredentialSecret.create_secret(
          %{
            name: "Chosen exec #{System.unique_integer([:positive])}",
            provider: "awx",
            credential_kind: :api_token,
            secret_payload: "chosen"
          },
          actor: system_actor()
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/ansible")

      lv |> element("button", "+ Add controller") |> render_click()

      lv
      |> form("#ansible-controller-form", %{
        "controller" => %{
          "name" => controller_name,
          "agent_id" => "k8s-agent",
          "description" => "",
          "base_url" => "http://awx-service.awx.svc.cluster.local",
          "sync_awx_api_token" => "sync-#{System.unique_integer([:positive])}",
          "execution_awx_api_token" => "",
          "callback_awx_api_token" => "",
          "execution_credential_secret_id" => exec_secret.id,
          "credential_secret_id" => "",
          "sync_credential_secret_id" => "",
          "callback_credential_secret_id" => "",
          "inventory_sync_interval_seconds" => "300",
          "catalog_sync_interval_seconds" => "600",
          "run_pulse_interval_ms" => "2000"
        }
      })
      |> render_submit()

      controller = controller_by_name!(controller_name)

      assert controller.execution_credential_secret_id == exec_secret.id
      assert controller.callback_credential_secret_id == nil
    end
  end
end
