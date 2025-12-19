defmodule ServiceRadarWebNG.Infrastructure.Poller do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false, source: :poller_id}
  @derive {Phoenix.Param, key: :id}
  schema "pollers" do
    field :component_id, :string
    field :registration_source, :string
    field :status, :string
    field :spiffe_identity, :string
    field :first_registered, :utc_datetime
    field :first_seen, :utc_datetime
    field :last_seen, :utc_datetime
    field :metadata, :map
    field :created_by, :string
    field :is_healthy, :boolean
    field :agent_count, :integer
    field :checker_count, :integer
    field :updated_at, :utc_datetime
  end
end
