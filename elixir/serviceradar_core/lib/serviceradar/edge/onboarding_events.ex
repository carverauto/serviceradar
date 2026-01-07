defmodule ServiceRadar.Edge.OnboardingEvents do
  @moduledoc """
  Ash-based context module for edge onboarding audit events.

  Provides functions to record and query audit events for edge onboarding packages.
  Events are stored in a TimescaleDB hypertable for efficient time-series queries.

  This module serves as a facade over the Ash OnboardingEvent resource,
  providing a familiar API for the rest of the application.

  ## Async Recording

  By default, events are recorded asynchronously via Oban to avoid blocking
  the main request. Use `record_sync/3` for synchronous recording when needed.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.OnboardingEvent
  alias ServiceRadar.Edge.Workers.RecordEventWorker

  @default_limit 50

  @doc """
  Lists events for a specific package, ordered by time descending.

  ## Options

    * `:limit` - Maximum number of events to return (default: 50)
    * `:actor` - The actor performing the query (required for authorization)

  ## Examples

      iex> list_for_package("package-uuid", actor: user)
      {:ok, [%OnboardingEvent{}, ...]}

  """
  @spec list_for_package(String.t(), keyword()) ::
          {:ok, [OnboardingEvent.t()]} | {:error, Ash.Error.t()}
  def list_for_package(package_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    actor = Keyword.get(opts, :actor)
    tenant_schema = tenant_schema_from_opts(opts)

    OnboardingEvent
    |> Ash.Query.for_read(:by_package, %{package_id: package_id}, actor: actor)
    |> Ash.Query.set_tenant(tenant_schema)
    |> Ash.Query.sort(event_time: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  @doc """
  Lists events for a specific package, returning empty list on error.

  This is a convenience function for contexts where authorization
  has already been verified.
  """
  @spec list_for_package!(String.t(), keyword()) :: [OnboardingEvent.t()]
  def list_for_package!(package_id, opts \\ []) do
    case list_for_package(package_id, opts) do
      {:ok, events} -> events
      {:error, _} -> []
    end
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

      iex> record("package-uuid", :created, actor: "admin@example.com")
      {:ok, %Oban.Job{}}

  """
  @spec record(String.t(), atom() | String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def record(package_id, event_type, opts \\ []) do
    tenant_schema = tenant_schema_from_opts(opts)

    RecordEventWorker.enqueue(package_id, event_type,
      Keyword.put(opts, :tenant_schema, tenant_schema)
    )
  end

  @doc """
  Records an audit event synchronously.

  Use this when you need to ensure the event is recorded before proceeding,
  such as in tests or critical audit scenarios.

  ## Options

    * `:actor` - User or system that performed the action (for authorization)
    * `:source_ip` - IP address of the actor
    * `:details` - Additional details map
    * `:event_time` - Override the event timestamp (default: now)

  """
  @spec record_sync(String.t(), atom() | String.t(), keyword()) ::
          {:ok, OnboardingEvent.t()} | {:error, Ash.Error.t()}
  def record_sync(package_id, event_type, opts \\ []) do
    actor = Keyword.get(opts, :actor_user) || build_system_actor(Keyword.get(opts, :actor))
    event_type_atom = normalize_event_type(event_type)
    tenant_schema = tenant_schema_from_opts(opts)

    attrs = %{
      event_time: Keyword.get(opts, :event_time, DateTime.utc_now()),
      package_id: package_id,
      event_type: event_type_atom,
      actor: stringify_actor(Keyword.get(opts, :actor)),
      source_ip: Keyword.get(opts, :source_ip),
      details_json: Keyword.get(opts, :details, %{})
    }

    OnboardingEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor, tenant: tenant_schema)
    |> Ash.create()
  end

  @doc """
  Records an event without returning an error on failure.
  Used for fire-and-forget audit logging where we don't want to fail the main operation.
  """
  @spec record!(String.t(), atom() | String.t(), keyword()) :: :ok
  def record!(package_id, event_type, opts \\ []) do
    record(package_id, event_type, opts)
    :ok
  end

  defp tenant_schema_from_opts(opts) do
    cond do
      schema = Keyword.get(opts, :tenant_schema) ->
        schema

      tenant = Keyword.get(opts, :tenant) ->
        TenantSchemas.schema_for_tenant(tenant)

      tenant_id = Keyword.get(opts, :tenant_id) ->
        TenantSchemas.schema_for_id(tenant_id)

      true ->
        nil
    end
  end

  @doc """
  Returns recent events across all packages.

  Useful for admin dashboards showing recent activity.

  ## Options

    * `:limit` - Maximum number of events (default: 50)
    * `:since` - Only return events after this DateTime
    * `:actor` - The actor performing the query (required for authorization)
  """
  @spec recent(keyword()) :: {:ok, [OnboardingEvent.t()]} | {:error, Ash.Error.t()}
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    since = Keyword.get(opts, :since)
    actor = Keyword.get(opts, :actor)

    query =
      if since do
        OnboardingEvent
        |> Ash.Query.for_read(:recent, %{since: since}, actor: actor)
      else
        OnboardingEvent
        |> Ash.Query.for_read(:read, %{}, actor: actor)
      end

    query
    |> Ash.Query.sort(event_time: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  @doc """
  Returns recent events, returning empty list on error.
  """
  @spec recent!(keyword()) :: [OnboardingEvent.t()]
  def recent!(opts \\ []) do
    case recent(opts) do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  # Helper to normalize event type to atom
  defp normalize_event_type(event_type) when is_atom(event_type), do: event_type

  defp normalize_event_type(event_type) when is_binary(event_type) do
    String.to_existing_atom(event_type)
  end

  # Helper to stringify actor for storage
  defp stringify_actor(nil), do: "system"
  defp stringify_actor(actor) when is_binary(actor), do: actor
  defp stringify_actor(%{email: email}), do: email
  defp stringify_actor(_), do: "system"

  # Build a system actor struct for internal operations
  defp build_system_actor(actor_name) do
    %{
      id: "system",
      email: actor_name || "system@serviceradar",
      role: :admin
    }
  end
end
