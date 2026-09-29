defmodule ServiceRadar.Repo.Migrations.AddAuthoredDashboardSourceProvenance do
  @moduledoc false
  use Ecto.Migration

  # Slugs of the reports this build seeds from priv/dashboards. They were created
  # before provenance existed, so they are the only rows a backfill can attribute
  # with certainty; any other dashboard was authored in the builder.
  @shipped_report_slugs ["new-devices", "mtr-path-analytics"]

  def up do
    alter table(:authored_dashboards, prefix: "platform") do
      add(:source_type, :text)
      add(:source_repo_url, :text)
      add(:source_ref, :text)
      add(:source_release_tag, :text)
      add(:source_commit, :text)
      add(:source_path, :text)
      add(:content_hash, :text)
      add(:signature, :map, null: false, default: %{})
    end

    create(
      constraint(:authored_dashboards, :authored_dashboards_source_type_check,
        prefix: "platform",
        check: "source_type IS NULL OR source_type IN ('upload', 'github', 'first_party')"
      )
    )

    slugs = Enum.map_join(@shipped_report_slugs, ", ", &"'#{&1}'")

    execute("""
    UPDATE platform.authored_dashboards
       SET source_type = 'first_party'
     WHERE source_type IS NULL
       AND slug IN (#{slugs})
       AND metadata->>'system_report' = 'true'
    """)
  end

  def down do
    drop(
      constraint(:authored_dashboards, :authored_dashboards_source_type_check, prefix: "platform")
    )

    alter table(:authored_dashboards, prefix: "platform") do
      remove(:signature)
      remove(:content_hash)
      remove(:source_path)
      remove(:source_commit)
      remove(:source_release_tag)
      remove(:source_ref)
      remove(:source_repo_url)
      remove(:source_type)
    end
  end
end
