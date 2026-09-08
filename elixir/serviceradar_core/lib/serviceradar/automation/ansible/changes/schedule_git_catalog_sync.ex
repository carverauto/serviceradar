defmodule ServiceRadar.Automation.Ansible.Changes.ScheduleGitCatalogSync do
  @moduledoc """
  Ash change that seeds the first `GitCatalogSyncWorker` job after a playbook
  repository write.

  The worker only re-schedules itself from `perform/1`, so without this hook a
  newly registered repository never got job #1 and sat at
  `last_sync_status: :pending` forever (nothing else enqueued it — the AWX
  lifecycle seeder only covered controller-scoped workers). Running it on
  update also picks up `git_url` / `git_ref` / credential changes without
  waiting for the periodic backstop.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Automation.Ansible.GitCatalogSyncWorker
  alias ServiceRadar.Changes.AfterAction

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &ensure_scheduled/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  # Runs inside the repository-write transaction (an Ash after_action hook).
  # It must never raise: a raised error would roll back the repository write
  # itself. Scheduling failures are logged and left to the lifecycle backstop
  # (`Lifecycle.seed_all/1`) to heal.
  defp ensure_scheduled(repository) do
    case GitCatalogSyncWorker.ensure_scheduled(repository.id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug("Git catalog sync scheduling deferred",
          repository_id: repository.id,
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.warning("Git catalog sync scheduling raised; deferred to backstop",
        repository_id: repository.id,
        reason: Exception.message(error)
      )

      :ok
  end
end
