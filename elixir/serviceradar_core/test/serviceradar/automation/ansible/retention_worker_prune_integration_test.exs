defmodule ServiceRadar.Automation.Ansible.RetentionWorkerPruneIntegrationTest do
  @moduledoc """
  DB-backed regression coverage for `RetentionWorker`'s reads against
  `PlaybookRun` / `PlaybookPlay`.

  Both resources deliberately have **no primary read action** (see
  `playbook_run.ex` — kept so state-transition updates don't attempt atomic
  upgrades). Every bare `Ash.read`/`Ash.bulk_destroy` therefore has to name the
  `:read` action explicitly, or Ash raises

      No primary action of type :read for resource
      ServiceRadar.Automation.Ansible.PlaybookRun, and no action specified

  which is exactly what crashed the Oban `RetentionWorker` on production
  installs (even with ansible otherwise disabled), in `old_terminal_run_ids/2`.

  This test drives the public `perform/1` against a seeded, aged terminal run so
  the read path in `old_terminal_run_ids/2` **and** the `PlaybookPlay`
  bulk_destroy read phase both execute for real. It is DB-gated; run with:

      mix test --include integration \\
        test/serviceradar/automation/ansible/retention_worker_prune_integration_test.exs
  """
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.RetentionWorker
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    prev_detail = Application.get_env(:serviceradar_core, :ansible_retention_run_detail_days)
    prev_summary = Application.get_env(:serviceradar_core, :ansible_retention_run_summary_days)

    on_exit(fn ->
      restore_env(:ansible_retention_run_detail_days, prev_detail)
      restore_env(:ansible_retention_run_summary_days, prev_summary)
    end)

    :ok
  end

  test "perform/1 prunes run details without the missing-primary-read crash" do
    # A detail cutoff must exist for the read paths to run at all; leave the
    # summary window disabled (the production default) so detail pruning keeps
    # the run row itself.
    Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, 90)
    Application.delete_env(:serviceradar_core, :ansible_retention_run_summary_days)

    run = seed_terminal_run(ended_at: DateTime.add(DateTime.utc_now(), -400, :day))

    # Before the fix this raised Ash.Error.Invalid.NoPrimaryAction from
    # old_terminal_run_ids/2's bare Ash.read! and, once reached, from the
    # PlaybookPlay bulk_destroy read phase.
    assert :ok = RetentionWorker.perform(%Oban.Job{})

    # Detail pruning drops the play/task hierarchy but retains the run row, so
    # the aged run must still be readable via the named :read action.
    assert [%{id: id}] = read_run(run.id)
    assert id == run.id
  end

  test "old_terminal_run_ids read path is a no-op on an empty detail window" do
    # Detail window set, but no aged rows: still exercises old_terminal_run_ids/2's
    # Ash.read! against PlaybookRun (the exact crash site) and must not raise.
    Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, 1)
    Application.delete_env(:serviceradar_core, :ansible_retention_run_summary_days)

    assert :ok = RetentionWorker.perform(%Oban.Job{})
  end

  defp seed_terminal_run(opts) do
    ended_at = Keyword.fetch!(opts, :ended_at)

    controller =
      Seed.seed!(Controller, %{
        name: "retention-test-#{System.unique_integer([:positive])}",
        base_url: "https://awx.test.invalid",
        agent_id: "agent-retention-test",
        credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    playbook =
      Seed.seed!(Playbook, %{
        source_type: :awx,
        name: "retention-test-playbook",
        controller_id: controller.id
      })

    Seed.seed!(PlaybookRun, %{
      playbook_id: playbook.id,
      controller_id: controller.id,
      state: :succeeded,
      started_at: DateTime.add(ended_at, -60, :second),
      ended_at: ended_at
    })
  end

  defp read_run(id) do
    actor = SystemActor.system(:test_retention_prune)

    PlaybookRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(actor: actor)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
