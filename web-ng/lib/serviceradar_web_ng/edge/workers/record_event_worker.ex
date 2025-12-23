defmodule ServiceRadarWebNG.Edge.Workers.RecordEventWorker do
  @moduledoc """
  Oban worker for asynchronously recording edge onboarding audit events.

  This allows the main request to complete without waiting for event logging,
  improving response times while maintaining audit trail integrity.
  """

  use Oban.Worker,
    queue: :events,
    max_attempts: 3,
    unique: [period: 60, keys: [:package_id, :event_type, :event_time]]

  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Edge.OnboardingEvent

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    event_time =
      case Map.get(args, "event_time") do
        nil -> DateTime.utc_now()
        ts when is_binary(ts) -> DateTime.from_iso8601(ts) |> elem(1)
        ts -> ts
      end

    event =
      OnboardingEvent.build(
        args["package_id"],
        args["event_type"],
        event_time: event_time,
        actor: args["actor"],
        source_ip: args["source_ip"],
        details: args["details"] || %{}
      )

    case Repo.insert(OnboardingEvent.changeset(event, %{})) do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Enqueues an event recording job.
  """
  def enqueue(package_id, event_type, opts \\ []) do
    args = %{
      "package_id" => package_id,
      "event_type" => event_type,
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "actor" => Keyword.get(opts, :actor),
      "source_ip" => Keyword.get(opts, :source_ip),
      "details" => Keyword.get(opts, :details, %{})
    }

    %{args: args}
    |> new()
    |> Oban.insert()
  end
end
