defmodule ServiceRadar.Repo.Migrations.AddNetflowInterfaceLastObservedAt do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:netflow_interface_cache, prefix: "platform") do
      add :last_observed_at, :utc_datetime_usec
    end

    execute """
    UPDATE platform.netflow_interface_cache
    SET last_observed_at = refreshed_at
    WHERE last_observed_at IS NULL
    """

    create index(:netflow_interface_cache, [:last_observed_at], prefix: "platform")
  end

  def down do
    alter table(:netflow_interface_cache, prefix: "platform") do
      remove :last_observed_at
    end
  end
end
