defmodule ServiceRadarWebNG.Edge.OnboardingEvents do
  @moduledoc """
  Context module for edge onboarding audit events.

  Provides functions to record and query audit events for edge onboarding packages.
  Events are stored in a TimescaleDB hypertable for efficient time-series queries.

  ## Async Recording

  By default, events are recorded asynchronously via Oban to avoid blocking
  the main request. Use `record_sync/3` for synchronous recording when needed.
  """

  import Ecto.Query
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Edge.OnboardingEvent
  alias ServiceRadarWebNG.Edge.Workers.RecordEventWorker

  @default_limit 50

  @doc """
  Lists events for a specific package, ordered by time descending.

  ## Options

    * `:limit` - Maximum number of events to return (default: 50)

  ## Examples

      iex> list_for_package("package-uuid", limit: 10)
      [%OnboardingEvent{}, ...]

  """
  @spec list_for_package(String.t(), keyword()) :: [OnboardingEvent.t()]
  def list_for_package(package_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    OnboardingEvent
    |> where([e], e.package_id == ^package_id)
    |> order_by([e], desc: e.event_time)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Records an audit event asynchronously via Oban.

  This is the preferred method for recording events as it doesn't block
  the main request. The event will be processed in the background.

  ## Options

    * `:actor` - User or system that performed the action
    * `:source_ip` - IP address of the actor
    * `:details` - Additional details map

  ## Examples

      iex> record("package-uuid", "created", actor: "admin@example.com")
      {:ok, %Oban.Job{}}

  """
  @spec record(String.t(), String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def record(package_id, event_type, opts \\ []) do
    RecordEventWorker.enqueue(package_id, event_type, opts)
  end

  @doc """
  Records an audit event synchronously.

  Use this when you need to ensure the event is recorded before proceeding,
  such as in tests or critical audit scenarios.

  ## Options

    * `:actor` - User or system that performed the action
    * `:source_ip` - IP address of the actor
    * `:details` - Additional details map
    * `:event_time` - Override the event timestamp (default: now)

  """
  @spec record_sync(String.t(), String.t(), keyword()) :: {:ok, OnboardingEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_sync(package_id, event_type, opts \\ []) do
    event = OnboardingEvent.build(package_id, event_type, opts)

    changeset = OnboardingEvent.changeset(event, %{})

    Repo.insert(changeset)
  end

  @doc """
  Records an event without returning an error on failure.
  Used for fire-and-forget audit logging where we don't want to fail the main operation.
  """
  @spec record!(String.t(), String.t(), keyword()) :: :ok
  def record!(package_id, event_type, opts \\ []) do
    record(package_id, event_type, opts)
    :ok
  end

  @doc """
  Returns recent events across all packages.

  Useful for admin dashboards showing recent activity.
  """
  @spec recent(keyword()) :: [OnboardingEvent.t()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    since = Keyword.get(opts, :since)

    OnboardingEvent
    |> maybe_filter_since(since)
    |> order_by([e], desc: e.event_time)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since) when is_struct(since, DateTime) do
    where(query, [e], e.event_time >= ^since)
  end
end
