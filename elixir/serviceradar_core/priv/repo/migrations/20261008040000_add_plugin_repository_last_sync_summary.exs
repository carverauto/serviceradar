defmodule ServiceRadar.Repo.Migrations.AddPluginRepositoryLastSyncSummary do
  @moduledoc """
  Per-run first-party plugin sync outcome on `platform.plugin_repositories`:
  counts and the first per-plugin failure of the last run, so the plugins page
  can show why a run failed without log access.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:plugin_repositories, prefix: @prefix) do
      add :last_sync_summary, :jsonb, null: true
    end
  end

  def down do
    alter table(:plugin_repositories, prefix: @prefix) do
      remove :last_sync_summary
    end
  end
end
