defmodule ServiceRadar.Automation.Ansible.RunWatchdogDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.RunWatchdog
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "perform/1 transitions stuck pending, launching, and running runs" do
    suffix = System.unique_integer([:positive])

    controller =
      Seed.seed!(Controller, %{
        name: "watchdog-test-#{suffix}",
        base_url: "https://awx.test.invalid",
        agent_id: "agent-watchdog-test",
        credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    playbook =
      Seed.seed!(Playbook, %{
        source_type: :awx,
        name: "watchdog-test-playbook-#{suffix}",
        controller_id: controller.id
      })

    old = DateTime.add(DateTime.utc_now(), -2, :hour)

    runs =
      Enum.map([:pending, :launching, :running], fn state ->
        Seed.seed!(PlaybookRun, %{
          playbook_id: playbook.id,
          controller_id: controller.id,
          state: state,
          started_at: if(state == :pending, do: nil, else: old),
          inserted_at: old
        })
      end)

    assert :ok = RunWatchdog.perform(%Oban.Job{})

    actor = SystemActor.system(:test_run_watchdog)

    Enum.each(runs, fn run ->
      assert {:ok, updated} = PlaybookRun.get_by_id(run.id, actor: actor)
      assert updated.state == :unreachable
      assert updated.diagnostics["watchdog"] == "exceeded watchdog threshold"
      assert is_binary(updated.diagnostics["marked_at"])
    end)
  end
end
