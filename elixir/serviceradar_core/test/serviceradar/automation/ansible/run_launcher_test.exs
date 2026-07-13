defmodule ServiceRadar.Automation.Ansible.RunLauncherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.RunLauncher

  test "legacy launch fails closed before persistence or dispatch" do
    assert {:error, :hardened_awx_targeting_required} =
             RunLauncher.launch(
               %{playbook_id: "uuid-1", device_uids: ["sr:a"]},
               actor: %{id: "user-1"}
             )
  end

  describe "validate_intent/1" do
    test "OK when playbook_id is present and device_uids is non-empty" do
      assert :ok =
               RunLauncher.validate_intent(%{
                 playbook_id: "uuid-1",
                 device_uids: ["sr:a", "sr:b"]
               })
    end

    test "missing playbook_id returns :playbook_required" do
      assert {:error, :playbook_required} =
               RunLauncher.validate_intent(%{playbook_id: nil, device_uids: ["sr:a"]})

      assert {:error, :playbook_required} =
               RunLauncher.validate_intent(%{playbook_id: "  ", device_uids: ["sr:a"]})

      assert {:error, :playbook_required} =
               RunLauncher.validate_intent(%{device_uids: ["sr:a"]})
    end

    test "missing or empty device_uids returns :devices_required" do
      assert {:error, :devices_required} =
               RunLauncher.validate_intent(%{playbook_id: "uuid-1", device_uids: []})

      assert {:error, :devices_required} =
               RunLauncher.validate_intent(%{playbook_id: "uuid-1"})

      assert {:error, :devices_required} =
               RunLauncher.validate_intent(%{playbook_id: "uuid-1", device_uids: "sr:a"})
    end
  end

  describe "resolve_controller_id/1" do
    test "awx-sourced playbook returns its controller_id" do
      assert {:ok, "ctrl-1"} =
               RunLauncher.resolve_controller_id(%{
                 source_type: :awx,
                 controller_id: "ctrl-1"
               })
    end

    test "git-sourced playbook returns :git_sourced_not_supported_v1" do
      assert {:error, :git_sourced_not_supported_v1} =
               RunLauncher.resolve_controller_id(%{
                 source_type: :git,
                 repository_id: "repo-1"
               })
    end

    test "awx-sourced without controller_id returns :playbook_unbound" do
      assert {:error, :playbook_unbound} =
               RunLauncher.resolve_controller_id(%{source_type: :awx, controller_id: nil})
    end

    test "unknown source_type returns :playbook_unbound" do
      assert {:error, :playbook_unbound} =
               RunLauncher.resolve_controller_id(%{source_type: :unknown})

      assert {:error, :playbook_unbound} = RunLauncher.resolve_controller_id(%{})
    end
  end
end
