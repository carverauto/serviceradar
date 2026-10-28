defmodule ServiceRadar.Automation.Ansible.AwxAssignmentResolutionDbTest do
  use ServiceRadar.DataCase, async: false

  import ServiceRadar.Observability.PluginResultRepairAssignmentSupport

  alias ServiceRadar.Automation.Ansible.AwxClient

  test "a sole enabled awx assignment on the agent is resolved" do
    {status, package} = awx_fixture()
    assignment = create_repair_assignment_for_package!(status, package)

    controller = %{agent_id: status.agent_id, base_url: "https://awx-a.example.invalid"}

    assert AwxClient.plugin_assignment_id_for(controller, nil) == to_string(assignment.id)
    assert AwxClient.awx_assignment_on_agent?(status.agent_id, to_string(assignment.id))
    refute AwxClient.awx_assignment_on_agent?(status.agent_id, Ecto.UUID.generate())
  end

  test "coexisting awx assignments resolve by the controller base_url in their params" do
    {status, package} = awx_fixture()
    suffix = System.unique_integer([:positive])

    primary =
      create_repair_assignment_for_package!(status, package,
        source: :policy,
        source_key: "awx-primary-#{suffix}",
        policy_id: "network-credential-rule:rule-awx-a-#{suffix}:inventory",
        params: %{"base_url" => "https://awx-a.example.invalid"}
      )

    secondary =
      create_repair_assignment_for_package!(status, package,
        source: :policy,
        source_key: "awx-secondary-#{suffix}",
        policy_id: "network-credential-rule:rule-awx-b-#{suffix}:inventory",
        params: %{"base_url" => "https://awx-b.example.invalid/"}
      )

    assert AwxClient.plugin_assignment_id_for(
             %{agent_id: status.agent_id, base_url: "https://awx-a.example.invalid"},
             nil
           ) == to_string(primary.id)

    assert AwxClient.plugin_assignment_id_for(
             %{agent_id: status.agent_id, base_url: "https://awx-b.example.invalid"},
             nil
           ) == to_string(secondary.id)

    assert AwxClient.plugin_assignment_id_for(
             %{agent_id: status.agent_id, base_url: "https://awx-c.example.invalid"},
             nil
           ) == nil
  end

  defp awx_fixture do
    suffix = System.unique_integer([:positive])

    status = %{
      agent_id: "awx-resolution-agent-#{suffix}",
      partition: "default",
      service_name: "awx-resolution-service-#{suffix}"
    }

    package = create_repair_package!(status.service_name, plugin_id: "awx")

    {status, package}
  end
end
