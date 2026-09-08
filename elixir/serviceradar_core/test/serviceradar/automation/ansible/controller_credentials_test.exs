defmodule ServiceRadar.Automation.Ansible.ControllerCredentialsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Controller

  @legacy "018f3f56-0000-7222-8333-123456789abc"
  @sync "018f3f56-1111-7222-8333-123456789abc"
  @execution "018f3f56-2222-7222-8333-123456789abc"
  @callback_secret "018f3f56-3333-7222-8333-123456789abc"

  test "new purpose-aware writes mirror sync into the deprecated column only" do
    changeset =
      Ash.Changeset.for_create(Controller, :create, %{
        name: "Purpose split",
        base_url: "https://awx.example.com",
        agent_id: "agent-a",
        sync_credential_secret_id: @sync,
        execution_credential_secret_id: @execution,
        callback_credential_secret_id: @callback_secret
      })

    assert Ash.Changeset.get_attribute(changeset, :credential_secret_id) == @sync
    assert Ash.Changeset.get_attribute(changeset, :sync_credential_secret_id) == @sync
    assert Ash.Changeset.get_attribute(changeset, :execution_credential_secret_id) == @execution

    assert Ash.Changeset.get_attribute(changeset, :callback_credential_secret_id) ==
             @callback_secret
  end

  test "one-release legacy writes populate sync but never execution or callback" do
    changeset =
      Ash.Changeset.for_create(Controller, :create, %{
        name: "Rolling upgrade",
        base_url: "https://awx.example.com",
        agent_id: "agent-a",
        credential_secret_id: @legacy
      })

    assert Ash.Changeset.get_attribute(changeset, :sync_credential_secret_id) == @legacy
    assert Ash.Changeset.get_attribute(changeset, :execution_credential_secret_id) == nil
    assert Ash.Changeset.get_attribute(changeset, :callback_credential_secret_id) == nil
  end

  test "purpose selector does not cross-fallback" do
    controller = %{
      credential_secret_id: @legacy,
      sync_credential_secret_id: @sync,
      execution_credential_secret_id: @execution,
      callback_credential_secret_id: @callback_secret
    }

    assert {:ok, @sync} = Controller.credential_secret_id_for(controller, :sync)
    assert {:ok, @execution} = Controller.credential_secret_id_for(controller, :execution)
    assert {:ok, @callback_secret} = Controller.credential_secret_id_for(controller, :callback)

    legacy_only = %{credential_secret_id: @legacy}
    assert {:ok, @legacy} = Controller.credential_secret_id_for(legacy_only, :sync)

    assert {:error, {:controller_credential_missing, :execution}} =
             Controller.credential_secret_id_for(legacy_only, :execution)

    assert {:error, {:controller_credential_missing, :callback}} =
             Controller.credential_secret_id_for(legacy_only, :callback)
  end
end
