defmodule ServiceRadarWebNG.Infrastructure.Service do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "services" do
    field :timestamp, :utc_datetime
    field :poller_id, :string
    field :agent_id, :string
    field :service_name, :string
    field :service_type, :string
    field :config, :map
    field :partition, :string
    field :created_at, :utc_datetime
  end
end
