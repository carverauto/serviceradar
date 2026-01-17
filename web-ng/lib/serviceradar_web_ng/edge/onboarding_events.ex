defmodule ServiceRadarWebNG.Edge.OnboardingEvents do
  @moduledoc """
  Context module for edge onboarding audit events.

  Delegates to ServiceRadar.Edge.OnboardingEvents Ash-based implementation
  while maintaining backwards compatibility with existing callers.

  This is a single-tenant instance - tenant context is implicit from the
  PostgreSQL search_path set by infrastructure.

  ## Async Recording

  By default, events are recorded asynchronously via Oban to avoid blocking
  the main request. Use `record_sync/3` for synchronous recording when needed.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingEvents, as: AshEvents
  alias ServiceRadar.Edge.OnboardingEvent

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
    opts = build_opts(opts)
    AshEvents.list_for_package!(package_id, opts)
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
  @spec record(String.t(), String.t() | atom(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def record(package_id, event_type, opts \\ []) do
    opts = build_opts(opts)
    AshEvents.record(package_id, event_type, opts)
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
  @spec record_sync(String.t(), String.t() | atom(), keyword()) ::
          {:ok, OnboardingEvent.t()} | {:error, Ash.Error.t()}
  def record_sync(package_id, event_type, opts \\ []) do
    opts = build_opts(opts)
    AshEvents.record_sync(package_id, event_type, opts)
  end

  @doc """
  Records an event without returning an error on failure.
  Used for fire-and-forget audit logging where we don't want to fail the main operation.
  """
  @spec record!(String.t(), String.t() | atom(), keyword()) :: :ok
  def record!(package_id, event_type, opts \\ []) do
    opts = build_opts(opts)
    AshEvents.record!(package_id, event_type, opts)
  end

  @doc """
  Returns recent events across all packages.

  Useful for admin dashboards showing recent activity.
  """
  @spec recent(keyword()) :: [OnboardingEvent.t()]
  def recent(opts \\ []) do
    opts = build_opts(opts)
    AshEvents.recent!(opts)
  end

  # Private helpers

  defp build_opts(opts) do
    actor = Keyword.get(opts, :actor) || system_actor()

    opts
    |> Keyword.put(:actor, actor)
    |> Keyword.put_new(:actor_user, actor)
  end

  defp system_actor do
    SystemActor.system(:onboarding_events)
  end
end
