defmodule ServiceRadarWebNG.Edge.OnboardingEvent do
  @moduledoc """
  Schema for edge onboarding audit events stored in the `edge_onboarding_events` table.

  This is a TimescaleDB hypertable with composite primary key (event_time, package_id).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "edge_onboarding_events" do
    field :event_time, :utc_datetime_usec, primary_key: true
    field :package_id, Ecto.UUID, primary_key: true
    field :event_type, :string
    field :actor, :string
    field :source_ip, :string
    field :details_json, :map, default: %{}
  end

  @required_fields ~w(event_time package_id event_type)a
  @optional_fields ~w(actor source_ip details_json)a

  @doc """
  Creates a changeset for inserting a new event.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, ~w(created delivered activated revoked deleted))
  end

  @doc """
  Builds an event struct for a package action.
  """
  def build(package_id, event_type, opts \\ []) do
    %__MODULE__{
      event_time: Keyword.get(opts, :event_time, DateTime.utc_now()),
      package_id: package_id,
      event_type: event_type,
      actor: Keyword.get(opts, :actor),
      source_ip: Keyword.get(opts, :source_ip),
      details_json: Keyword.get(opts, :details, %{})
    }
  end
end
