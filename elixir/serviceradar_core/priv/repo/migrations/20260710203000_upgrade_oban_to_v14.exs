defmodule ServiceRadar.Repo.Migrations.UpgradeObanToV14 do
  @moduledoc false

  use Ecto.Migration

  @prefix "platform"

  def up do
    Oban.Migrations.up(prefix: @prefix, version: 14)
  end

  def down do
    # This migration repairs databases already running the v14 Oban runtime.
    # Downgrading only the schema metadata would make that runtime refuse to start.
    :ok
  end
end
