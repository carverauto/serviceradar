defmodule ServiceRadarWebNG.Jobs.Schedule do
  use Ecto.Schema

  import Ecto.Changeset

  alias Oban.Cron.Expression

  schema "ng_job_schedules" do
    field :job_key, :string
    field :cron, :string
    field :timezone, :string, default: "Etc/UTC"
    field :args, :map, default: %{}
    field :enabled, :boolean, default: true
    field :unique_period_seconds, :integer
    field :last_enqueued_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:cron, :enabled, :timezone, :args, :unique_period_seconds])
    |> validate_required([:cron, :timezone])
    |> validate_length(:cron, min: 1, max: 100)
    |> validate_change(:cron, &validate_cron/2)
    |> validate_number(:unique_period_seconds, greater_than: 0)
  end

  defp validate_cron(:cron, cron) do
    case Expression.parse(cron) do
      {:ok, _} -> []
      {:error, error} -> [cron: "invalid cron expression: #{Exception.message(error)}"]
    end
  end
end
