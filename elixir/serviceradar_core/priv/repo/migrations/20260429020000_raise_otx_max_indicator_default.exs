defmodule ServiceRadar.Repo.Migrations.RaiseOtxMaxIndicatorDefault do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:netflow_settings, prefix: "platform") do
      modify :otx_max_indicators, :integer, null: false, default: 50_000
    end
  end

  def down do
    alter table(:netflow_settings, prefix: "platform") do
      modify :otx_max_indicators, :integer, null: false, default: 5_000
    end
  end
end
