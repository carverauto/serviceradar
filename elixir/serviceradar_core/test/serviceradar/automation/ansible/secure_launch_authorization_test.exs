defmodule ServiceRadar.Automation.Ansible.SecureLaunchAuthorizationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Playbook

  @moduletag :requires_app

  @launch_actor %{
    id: "user:ansible-launcher",
    role: :viewer,
    permissions: MapSet.new(["ansible.runs.launch"]),
    profile_versions: []
  }

  test "launch permission authorizes every resolver read needed for a secure launch" do
    assert Ash.can?({Playbook, :launchable}, @launch_actor)
    assert Ash.can?({Playbook, :launch_candidate_by_id}, @launch_actor)

    assert Ash.can?({AwxTemplateBinding, :current_approved_for_template}, @launch_actor)

    assert Ash.can?({AwxHostMembership, :current_for_device}, @launch_actor)
  end
end
