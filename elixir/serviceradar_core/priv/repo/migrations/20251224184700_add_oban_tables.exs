defmodule ServiceRadar.Repo.Migrations.AddObanTables do
  @moduledoc """
  Creates the Oban job queue tables.
  """
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
