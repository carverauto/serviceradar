defmodule ServiceRadar.Repo.Migrations.AddCameraSourceStateFields do
  use Ecto.Migration

  def change do
    alter table(:camera_sources, prefix: "platform") do
      add :availability_status, :text
      add :availability_reason, :text
      add :last_activity_at, :utc_datetime_usec
      add :last_event_at, :utc_datetime_usec
      add :last_event_type, :text
      add :last_event_message, :text
    end
  end
end
