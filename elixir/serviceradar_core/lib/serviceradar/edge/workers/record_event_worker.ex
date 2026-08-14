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
    unique: [period: :infinity, keys: [:package_id, :event_type, :event_time]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingEvent
  alias ServiceRadar.Oban.Router

  @event_types [:created, :delivered, :activated, :revoked, :deleted, :expired]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, attrs} <- cast_args(args) do
      actor = SystemActor.system(:record_event)

      case OnboardingEvent
           |> Ash.Changeset.for_create(:record, attrs, actor: actor)
           |> Ash.create() do
        {:ok, _event} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  Enqueues an event recording job.
  """
  @spec enqueue(String.t(), String.t() | atom(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(package_id, event_type, opts \\ []) do
    with {:ok, event_type_atom} <- normalize_event_type(event_type) do
      %{
        "package_id" => package_id,
        "event_type" => Atom.to_string(event_type_atom),
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "actor" => stringify_actor(Keyword.get(opts, :actor)),
        "source_ip" => stringify_optional(Keyword.get(opts, :source_ip)),
        "details" => Keyword.get(opts, :details, %{})
      }
      |> new()
      |> Router.insert()
    end
  end

  @doc false
  def cast_args(args) when is_map(args) do
    args = unwrap_args(args)

    with {:ok, event_type} <- normalize_event_type(fetch_arg(args, "event_type")) do
      {:ok,
       %{
         event_time: parse_event_time(fetch_arg(args, "event_time")),
         package_id: fetch_arg(args, "package_id"),
         event_type: event_type,
         actor: stringify_actor(fetch_arg(args, "actor")),
         source_ip: stringify_optional(fetch_arg(args, "source_ip")),
         details_json: fetch_arg(args, "details") || %{}
       }}
    end
  end

  def cast_args(_), do: {:discard, :invalid_event_args}

  # Old enqueue/3 called `new(%{args: inner})`, so Oban stored
  # %{"args" => %{"event_type" => ..., ...}}. perform/1 then saw a nil
  # event_type and crashed in String.to_existing_atom/1.
  defp unwrap_args(%{"args" => inner}) when is_map(inner), do: unwrap_args(inner)
  defp unwrap_args(%{args: inner}) when is_map(inner), do: unwrap_args(inner)
  defp unwrap_args(args), do: args

  defp fetch_arg(args, "event_type"),
    do: Map.get(args, "event_type") || Map.get(args, :event_type)

  defp fetch_arg(args, "event_time"),
    do: Map.get(args, "event_time") || Map.get(args, :event_time)

  defp fetch_arg(args, "package_id"),
    do: Map.get(args, "package_id") || Map.get(args, :package_id)

  defp fetch_arg(args, "actor"), do: Map.get(args, "actor") || Map.get(args, :actor)
  defp fetch_arg(args, "source_ip"), do: Map.get(args, "source_ip") || Map.get(args, :source_ip)
  defp fetch_arg(args, "details"), do: Map.get(args, "details") || Map.get(args, :details)

  defp normalize_event_type(type) when type in @event_types, do: {:ok, type}

  defp normalize_event_type(type) when is_binary(type) do
    case Enum.find(@event_types, &(Atom.to_string(&1) == type)) do
      nil -> {:discard, :invalid_event_type}
      atom -> {:ok, atom}
    end
  end

  defp normalize_event_type(_), do: {:discard, :invalid_event_type}

  defp stringify_actor(nil), do: "system"
  defp stringify_actor(actor) when is_binary(actor), do: actor
  defp stringify_actor(%{email: email}) when is_binary(email), do: email
  defp stringify_actor(_), do: "system"

  defp stringify_optional(nil), do: nil
  defp stringify_optional(value) when is_binary(value), do: value
  defp stringify_optional(value), do: to_string(value)

  defp parse_event_time(nil), do: DateTime.utc_now()

  defp parse_event_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_event_time(%DateTime{} = ts), do: ts
  defp parse_event_time(_), do: DateTime.utc_now()
end
