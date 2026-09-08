defmodule ServiceRadar.Repo.Migrations.AddSamplingRateToOcsfNetworkActivity do
  @moduledoc false

  use Ecto.Migration

  def up do
    alter table(:ocsf_network_activity, prefix: "platform") do
      add :sampling_rate, :bigint, null: false, default: 1
    end

    execute("""
    COMMENT ON COLUMN platform.ocsf_network_activity.sampling_rate IS
      'Exporter sampling multiplier for sampled NetFlow/IPFIX/sFlow records; 1 means unsampled'
    """)
  end

  def down do
    alter table(:ocsf_network_activity, prefix: "platform") do
      remove :sampling_rate
    end
  end
end
