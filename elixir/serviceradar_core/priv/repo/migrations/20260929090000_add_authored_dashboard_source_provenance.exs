defmodule ServiceRadar.Repo.Migrations.AddAuthoredDashboardSourceProvenance do
  @moduledoc false
  use Ecto.Migration

  # No backfill: rows created before this keep NULL provenance, because the release,
  # commit and hash they came from were never recorded. Migrations newer than the
  # baseline also must not do data work on the first-boot path.

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
