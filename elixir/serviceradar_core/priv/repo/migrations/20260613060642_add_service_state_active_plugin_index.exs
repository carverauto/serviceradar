defmodule ServiceRadar.Repo.Migrations.AddServiceStateActivePluginIndex do
  @moduledoc false
  use Ecto.Migration

  def change do
    create_if_not_exists index(:service_state, [:service_type, :state, :last_observed_at],
                           name: "service_state_active_plugin_index",
                           prefix: "platform",
                           where: "service_type = 'plugin' AND state = 'active'"
                         )
  end
end
