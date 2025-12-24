defmodule ServiceRadar.Edge.Workers.RecordEventWorker do
  @moduledoc """
  Oban worker for asynchronously recording edge onboarding audit events.

  Uses Ash to create events, ensuring proper authorization and validation.
  This allows the main request to complete without waiting for event logging,
  improving response times while maintaining audit trail integrity.
  """

  use Oban.Worker,
    queue: :events,
    max_attempts: 3,
    unique: [period: 60, keys: [:package_id, :event_type, :event_time]]

  alias ServiceRadar.Edge.OnboardingEvent

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    event_time = parse_event_time(args["event_time"])

    # Create a system actor for background job authorization
    actor = build_system_actor(args["actor"])

    attrs = %{
      event_time: event_time,
      package_id: args["package_id"],
      event_type: String.to_existing_atom(args["event_type"]),
      actor: args["actor"],
      source_ip: args["source_ip"],
      details_json: args["details"] || %{}
    }

    case OnboardingEvent
         |> Ash.Changeset.for_create(:record, attrs, actor: actor)
         |> Ash.create() do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Enqueues an event recording job.
  """
  @spec enqueue(String.t(), String.t() | atom(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(package_id, event_type, opts \\ []) do
    event_type_str =
      if is_atom(event_type), do: Atom.to_string(event_type), else: event_type

    args = %{
      "package_id" => package_id,
      "event_type" => event_type_str,
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "actor" => Keyword.get(opts, :actor),
      "source_ip" => Keyword.get(opts, :source_ip),
      "details" => Keyword.get(opts, :details, %{})
    }

    %{args: args}
    |> new()
    |> Oban.insert()
  end

  defp parse_event_time(nil), do: DateTime.utc_now()

  defp parse_event_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_event_time(ts), do: ts

  # Build a system actor struct for background job authorization
  # This provides admin-level access for event recording
  defp build_system_actor(actor_name) do
    %{
      id: "system",
      email: actor_name || "system@serviceradar",
      role: :admin
    }
  end
end
