defmodule ServiceRadar.Repo.Migrations.BindCameraSourceIncarnation do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:camera_relay_sessions, prefix: "platform") do
      add :source_incarnation_id, :uuid
    end
  end
end
