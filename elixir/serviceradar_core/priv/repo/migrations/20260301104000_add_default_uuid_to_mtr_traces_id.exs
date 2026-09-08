defmodule ServiceRadar.Repo.Migrations.AddDefaultUuidToMtrTracesId do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.mtr_traces
    ALTER COLUMN id SET DEFAULT gen_random_uuid()
    """)
  end

  def down do
    execute("""
    ALTER TABLE platform.mtr_traces
    ALTER COLUMN id DROP DEFAULT
    """)
  end
end
