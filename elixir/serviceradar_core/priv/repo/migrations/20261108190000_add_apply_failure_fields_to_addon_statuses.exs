defmodule ServiceRadar.Repo.Migrations.AddApplyFailureFieldsToAddonStatuses do
  use Ecto.Migration

  def up do
    alter table(:addon_statuses, prefix: "platform") do
      add_if_not_exists :desired_version, :text
      add_if_not_exists :apply_error, :text
      add_if_not_exists :apply_disposition, :text
      add_if_not_exists :apply_observed_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:addon_statuses, prefix: "platform") do
      remove_if_exists :desired_version, :text
      remove_if_exists :apply_error, :text
      remove_if_exists :apply_disposition, :text
      remove_if_exists :apply_observed_at, :utc_datetime_usec
    end
  end
end
