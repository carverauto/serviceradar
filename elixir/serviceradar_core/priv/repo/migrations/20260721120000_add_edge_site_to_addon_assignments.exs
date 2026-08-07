defmodule ServiceRadar.Repo.Migrations.AddEdgeSiteToAddonAssignments do
  @moduledoc """
  Associates an optional native add-on assignment with the registered edge site
  whose local NATS leaf may be used by an explicitly direct JetStream add-on.
  """

  use Ecto.Migration

  def up do
    alter table(:addon_assignments, prefix: "platform") do
      add(
        :edge_site_id,
        references(:edge_sites,
          column: :id,
          type: :uuid,
          prefix: "platform",
          on_delete: :nilify_all,
          name: "addon_assignments_edge_site_id_fkey"
        )
      )
    end

    create(
      index(:addon_assignments, [:edge_site_id],
        name: "addon_assignments_edge_site_id_index",
        prefix: "platform"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:addon_assignments, [:edge_site_id],
        name: "addon_assignments_edge_site_id_index",
        prefix: "platform"
      )
    )

    drop(
      constraint(:addon_assignments, "addon_assignments_edge_site_id_fkey", prefix: "platform")
    )

    alter table(:addon_assignments, prefix: "platform") do
      remove(:edge_site_id)
    end
  end
end
