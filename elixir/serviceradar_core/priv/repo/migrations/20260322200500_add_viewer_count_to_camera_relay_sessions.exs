defmodule ServiceRadar.Repo.Migrations.AddViewerCountToCameraRelaySessions do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:camera_relay_sessions, prefix: "platform") do
      add :viewer_count, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:camera_relay_sessions, prefix: "platform") do
      remove :viewer_count
    end
  end
end
