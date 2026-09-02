defmodule ServiceRadar.Automation.Ansible.PlaybookRunTargetForDeviceTest do
  @moduledoc """
  DB-backed regression coverage for the device-details Ansible panel run-history
  load chain.

  The panel calls `PlaybookRunTarget.list_for_device/2`, whose `:for_device`
  read action ends with `prepare build(..., load: [run: [:playbook]])`. Loading
  the `run` relationship requires `PlaybookRun` to expose a **primary read
  action** — and until this fix only `Playbook` had one (#4492/#4495). Every
  other resource in the run hierarchy (`PlaybookRun`, `PlaybookRunTarget`,
  `PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult`, `PlaybookContent`,
  `Controller`, `PlaybookSchedule`, `PlaybookRepository`) was missing one, so the
  first time a device actually had a run the panel raised

      (RuntimeError) Required primary read action for
      ServiceRadar.Automation.Ansible.PlaybookRun

  which crash-looped the LiveView. These tests drive the real relationship-load
  paths that regress that class of bug.

  DB-gated; run with:

      mix test --include integration \\
        test/serviceradar/automation/ansible/playbook_run_target_for_device_test.exs
  """
  use ServiceRadar.DataCase, async: true

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookContent
  alias ServiceRadar.Automation.Ansible.PlaybookPlay
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Ansible.PlaybookSchedule
  alias ServiceRadar.Automation.Ansible.PlaybookTask
  alias ServiceRadar.Automation.Ansible.PlaybookTaskResult
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tag = System.unique_integer([:positive])
    device_uid = "sr:for-device-test-#{tag}"

    controller = seed_controller(tag)
    playbook = seed_awx_playbook(controller.id, tag)
    schedule = seed_schedule(playbook.id, tag)
    run = seed_run(playbook.id, controller.id, schedule.id, tag)
    target = seed_target(run.id, device_uid, tag)
    play = seed_play(run.id, tag)
    task = seed_task(play.id, tag)
    content = seed_content(tag)
    result = seed_task_result(task.id, target.id, content.id, tag)

    %{
      device_uid: device_uid,
      controller: controller,
      playbook: playbook,
      schedule: schedule,
      run: run,
      target: target,
      play: play,
      task: task,
      content: content,
      result: result
    }
  end

  test "list_for_device resolves the run/playbook load chain (the crash path)", ctx do
    # This is the exact call the device panel makes; `:for_device` loads
    # `run: [:playbook]`, which is what raised "Required primary read action".
    assert {:ok, [target]} = PlaybookRunTarget.list_for_device(ctx.device_uid, actor: actor())

    assert target.id == ctx.target.id
    assert %PlaybookRun{} = target.run
    assert target.run.id == ctx.run.id
    assert %Playbook{} = target.run.playbook
    assert target.run.playbook.id == ctx.playbook.id
  end

  test "the full run drill-down resolves via relationship loads", ctx do
    assert {:ok, run} = PlaybookRun.get_by_id(ctx.run.id, actor: actor())

    # Every relationship here is a load through a resource that previously had
    # no primary read: controller / schedule / targets / task_results /
    # stdout_content / plays / tasks / results.
    assert {:ok, loaded} =
             Ash.load(
               run,
               [
                 :controller,
                 :playbook,
                 :schedule,
                 targets: [task_results: [:stdout_content]],
                 plays: [tasks: [:results]]
               ],
               actor: actor()
             )

    assert %Controller{id: cid} = loaded.controller
    assert cid == ctx.controller.id
    assert %PlaybookSchedule{id: sid} = loaded.schedule
    assert sid == ctx.schedule.id

    assert [%PlaybookRunTarget{} = t] = loaded.targets
    assert [%PlaybookTaskResult{} = r] = t.task_results
    assert %PlaybookContent{id: content_id} = r.stdout_content
    assert content_id == ctx.content.id

    assert [%PlaybookPlay{} = p] = loaded.plays
    assert [%PlaybookTask{} = task] = p.tasks
    assert [%PlaybookTaskResult{}] = task.results
  end

  test "catalog chain resolves the repository relationship", _ctx do
    repo = seed_repository(System.unique_integer([:positive]))
    git_playbook = seed_git_playbook(repo.id)

    assert {:ok, loaded} = Ash.load(git_playbook, [:repository], actor: actor())
    assert %PlaybookRepository{id: rid} = loaded.repository
    assert rid == repo.id
  end

  ## Actor ---------------------------------------------------------------------

  defp actor, do: SystemActor.system(:test_for_device_primary_read)

  ## Seeds ---------------------------------------------------------------------

  defp seed_controller(tag) do
    Seed.seed!(Controller, %{
      name: "for-device-test-#{tag}",
      base_url: "https://awx.test.invalid",
      agent_id: "agent-for-device-test",
      credential_secret_id: CredentialIntegrationFixtures.secret_id!()
    })
  end

  defp seed_awx_playbook(controller_id, tag) do
    Seed.seed!(Playbook, %{
      source_type: :awx,
      name: "for-device-#{tag}-awx",
      controller_id: controller_id,
      awx_job_template_id: 100 + rem(tag, 1000)
    })
  end

  defp seed_schedule(playbook_id, tag) do
    Seed.seed!(PlaybookSchedule, %{
      name: "for-device-sched-#{tag}",
      playbook_id: playbook_id,
      cron: "0 * * * *"
    })
  end

  defp seed_run(playbook_id, controller_id, schedule_id, _tag) do
    Seed.seed!(PlaybookRun, %{
      playbook_id: playbook_id,
      controller_id: controller_id,
      schedule_id: schedule_id,
      state: :succeeded,
      awx_job_id: nil
    })
  end

  defp seed_target(run_id, device_uid, tag) do
    Seed.seed!(PlaybookRunTarget, %{
      run_id: run_id,
      device_uid: device_uid,
      awx_host_name: "host-#{tag}",
      status: :ok
    })
  end

  defp seed_play(run_id, tag) do
    Seed.seed!(PlaybookPlay, %{
      run_id: run_id,
      awx_play_uuid: "play-#{tag}",
      name: "Play #{tag}"
    })
  end

  defp seed_task(play_id, tag) do
    Seed.seed!(PlaybookTask, %{
      play_id: play_id,
      awx_task_uuid: "task-#{tag}",
      name: "Task #{tag}"
    })
  end

  defp seed_content(tag) do
    payload = "output-#{tag}"

    Seed.seed!(PlaybookContent, %{
      sha256: :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower),
      payload: payload,
      size_bytes: byte_size(payload)
    })
  end

  defp seed_task_result(task_id, run_target_id, content_id, tag) do
    Seed.seed!(PlaybookTaskResult, %{
      task_id: task_id,
      run_target_id: run_target_id,
      awx_event_id: 1_000 + rem(tag, 1_000_000),
      status: :ok,
      stdout_content_id: content_id
    })
  end

  defp seed_repository(tag) do
    Seed.seed!(PlaybookRepository, %{
      name: "for-device-repo-#{tag}",
      git_url: "https://github.com/example/playbooks-#{tag}.git",
      git_ref: "main"
    })
  end

  defp seed_git_playbook(repository_id) do
    Seed.seed!(Playbook, %{
      source_type: :git,
      name: "for-device-git-#{System.unique_integer([:positive])}",
      repository_id: repository_id,
      path: "playbooks/site.yml"
    })
  end
end
