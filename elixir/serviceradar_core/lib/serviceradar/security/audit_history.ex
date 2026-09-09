defmodule ServiceRadar.Security.AuditHistory do
  @moduledoc """
  Cross-resource read surface over the AshPaperTrail `<Resource>.Version`
  sibling modules, unioned with `ServiceRadar.Observability.ApiEvent`
  (AshEvents) rows for resources opted into that mechanism. Returns a
  merged, time-ordered list so the Settings → Audit → History LiveView can
  render one timeline regardless of which auditing mechanism a resource
  uses.

  The PaperTrail allow-list lives at
  `config :serviceradar_core, #{__MODULE__}, resources: [...]`; the
  AshEvents allow-list at
  `config :serviceradar_core, #{__MODULE__}, ash_events_resources: [...]`.
  These are deliberately separate lists (`resources/0` is PaperTrail-only)
  because the two mechanisms have different adoption boundaries — see
  `openspec/changes/add-ash-events-audit-log/design.md#decisions`. Operators
  may include or exclude specific resources in either without touching this
  module.

  Every `ApiEvent` row is adapted into an `ApiEventVersion` struct exposing
  the same field names AshPaperTrail's `<Resource>.Version` modules use
  (`version_inserted_at`, `version_action_type`, `changes`,
  `version_action_inputs`, `version_source_id`), so the existing History
  LiveView template and its `extract_actor/1` helper need no changes to
  render either kind of row. The one addition is `origin` on the merged
  entry (`"api"` / `"web"` / `nil`), read from the AshEvents
  `metadata["source"]` field.

  Per-resource Ash policies still gate the version/event reads — calling
  `list_recent/2` with an actor that can't read a particular resource's
  history transparently drops those rows from the result. Pagination keeps
  its shape because the merge happens after the per-resource reads.
  """

  alias ServiceRadar.Observability.ApiEvent

  require Ash.Query

  defmodule ApiEventVersion do
    @moduledoc """
    Adapts an `ApiEvent` row to the field names AshPaperTrail's
    `<Resource>.Version` modules use, so the History LiveView template and
    `extract_actor/1` can render both kinds of row identically.
    """
    defstruct [
      :id,
      :version_inserted_at,
      :version_action_type,
      :changes,
      :version_action_inputs,
      :version_source_id
    ]
  end

  @default_limit 50
  @default_offset 0

  @default_resources [
    ServiceRadar.Credentials.NetworkCredentialSecret,
    ServiceRadar.Credentials.NetworkCredentialRule,
    ServiceRadar.Edge.ProxmoxConsoleSession,
    ServiceRadar.Automation.Ansible.Controller,
    ServiceRadar.Automation.Ansible.Playbook,
    ServiceRadar.Automation.Ansible.PlaybookRun,
    ServiceRadar.Automation.Ansible.PlaybookSchedule,
    ServiceRadar.Automation.Ansible.PlaybookRepository,
    ServiceRadar.Automation.Northbound.ActionProvider,
    ServiceRadar.Automation.Northbound.ActionDescriptor,
    ServiceRadar.Automation.Northbound.ActionInvocation,
    ServiceRadar.Automation.Northbound.ActionEventHandler,
    ServiceRadar.Inventory.VisibilityProfile,
    ServiceRadar.Security.AuthLockout,
    ServiceRadar.Dashboards.AuthoredDashboard,
    ServiceRadar.Dashboards.DashboardReportSchedule
  ]

  # AshEvents-backed resources, distinct from `@default_resources` (which is
  # PaperTrail-specific). Only resources with an `events do event_log
  # ServiceRadar.Observability.ApiEvent end` block belong here -- currently
  # only `StatefulAlertRule`, per the adoption boundary in
  # `openspec/changes/add-ash-events-audit-log/design.md#decisions`.
  @default_ash_events_resources [
    ServiceRadar.Observability.StatefulAlertRule
  ]

  @doc """
  Returns the configured allow-list of AshPaperTrail-enabled
  resources. Operators override via
  `config :serviceradar_core, #{__MODULE__}, resources: [...]`.
  """
  @spec resources() :: [module()]
  def resources do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:resources, @default_resources)
  end

  @doc """
  Returns the configured allow-list of AshEvents-enabled resources
  (resources that record into `ServiceRadar.Observability.ApiEvent`).
  Operators override via
  `config :serviceradar_core, #{__MODULE__}, ash_events_resources: [...]`.
  """
  @spec ash_events_resources() :: [module()]
  def ash_events_resources do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ash_events_resources, @default_ash_events_resources)
  end

  @doc """
  Returns the union of both allow-lists, for callers (the History
  LiveView's resource filter) that don't need to distinguish which
  auditing mechanism a resource uses.
  """
  @spec all_resources() :: [module()]
  def all_resources, do: Enum.uniq(resources() ++ ash_events_resources())

  @doc """
  Returns the most recent version rows across the allow-list,
  merged and sorted by `version_inserted_at` desc.

  ## Options

    * `:resource_types` — list of resource modules to restrict the
      query to. Defaults to the full allow-list.
    * `:actor_id` — string identifier to match against
      `version_action_inputs` (looked up under common shapes:
      `actor.id`, `actor.email`, or top-level `actor`).
    * `:action_types` — list of strings (e.g. `["create", "update",
      "destroy"]`). Defaults to all.
    * `:since`, `:until` — `DateTime` bounds against
      `version_inserted_at`.
    * `:limit` — page size after merge. Default 50.
    * `:offset` — page offset after merge. Default 0.
    * `:actor` — Ash actor passed to the per-resource version
      reads so RBAC stays in force. Required.
  """
  @spec list_recent(keyword()) :: [%{resource: module(), version: struct()}]
  def list_recent(opts \\ []) do
    actor = Keyword.get(opts, :actor)
    resource_types = Keyword.get(opts, :resource_types, all_resources())
    actor_id = Keyword.get(opts, :actor_id)
    action_types = Keyword.get(opts, :action_types)
    since = Keyword.get(opts, :since)
    until_ = Keyword.get(opts, :until)
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, @default_offset)

    # Read more than `limit` from each resource so the merged
    # window has room: take offset + limit from each, then
    # globally sort and slice.
    per_source = offset + limit

    paper_trail_entries =
      resource_types
      |> Enum.filter(&(&1 in resources()))
      |> Enum.flat_map(&read_versions(&1, actor, since, until_, action_types, per_source))

    ash_events_entries =
      resource_types
      |> Enum.filter(&(&1 in ash_events_resources()))
      |> read_ash_events(actor, actor_id, since, until_, action_types, per_source)

    (paper_trail_entries ++ ash_events_entries)
    |> Enum.filter(&matches_actor?(&1, actor_id))
    |> Enum.sort_by(& &1.version.version_inserted_at, {:desc, DateTime})
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  ## Per-resource reads

  defp read_versions(resource, actor, since, until_, action_types, n) do
    version_module = Module.concat(resource, Version)

    if Code.ensure_loaded?(version_module) do
      version_module
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> apply_time_filters(since, until_)
      |> apply_action_filter(action_types)
      |> Ash.Query.sort(version_inserted_at: :desc)
      |> Ash.Query.limit(n)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, versions} ->
          # `origin` is nil for PaperTrail rows -- rendered as "—" by the
          # LiveView's Source column, distinct from AshEvents rows below
          # which always carry "api" or "web".
          Enum.map(versions, &%{resource: resource, version: &1, origin: nil})

        {:error, _reason} ->
          # Per-resource read may fail under RBAC — treat as empty.
          []
      end
    else
      []
    end
  rescue
    # Never let a single resource's failure poison the whole timeline.
    _ -> []
  end

  ## AshEvents reads (ApiEvent, adapted to the PaperTrail Version shape)

  defp read_ash_events([], _actor, _actor_id, _since, _until_, _action_types, _n), do: []

  defp read_ash_events(wanted_resources, actor, actor_id, since, until_, action_types, n) do
    ApiEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(resource in ^wanted_resources)
    |> apply_ash_events_time_filters(since, until_)
    |> apply_ash_events_action_filter(action_types)
    |> apply_ash_events_actor_filter(actor_id)
    |> Ash.Query.limit(n)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, events} -> Enum.map(events, &adapt_ash_event/1)
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  defp adapt_ash_event(event) do
    %{
      resource: event.resource,
      origin: event.metadata["source"] || "—",
      version: %ApiEventVersion{
        id: event.id,
        version_inserted_at: event.occurred_at,
        version_action_type: to_string(event.action_type),
        changes: event.changed_attributes,
        version_action_inputs: version_action_inputs(event),
        version_source_id: event.record_id
      }
    }
  end

  # `event.user_id` is only populated when the actor passed to the action was
  # a real `%ServiceRadar.Identity.User{}` struct (AshEvents'
  # `persist_actor_primary_key` requires an exact struct-type match -- see
  # `ServiceRadar.Observability.Changes.StampEventSource`'s moduledoc). Real
  # requests build a plain-map actor instead, so fall back to
  # `metadata["actor_id"]`, which that change stamps independently of actor
  # shape.
  defp version_action_inputs(event) do
    actor_id =
      cond do
        event.user_id -> to_string(event.user_id)
        is_binary(event.metadata["actor_id"]) -> event.metadata["actor_id"]
        true -> nil
      end

    if actor_id do
      Map.put(event.data || %{}, "actor", %{"id" => actor_id})
    else
      event.data || %{}
    end
  end

  defp apply_ash_events_actor_filter(query, actor_id) when actor_id in [nil, ""], do: query

  defp apply_ash_events_actor_filter(query, actor_id) do
    actor_id = to_string(actor_id)

    Ash.Query.filter(
      query,
      type(user_id, :string) == ^actor_id or
        (is_nil(user_id) and get_path(metadata, ["actor_id"]) == ^actor_id)
    )
  end

  defp apply_ash_events_time_filters(query, nil, nil), do: query

  defp apply_ash_events_time_filters(query, since, nil) do
    require Ash.Expr

    Ash.Query.filter(query, Ash.Expr.expr(occurred_at >= ^since))
  end

  defp apply_ash_events_time_filters(query, nil, until_) do
    require Ash.Expr

    Ash.Query.filter(query, Ash.Expr.expr(occurred_at <= ^until_))
  end

  defp apply_ash_events_time_filters(query, since, until_) do
    require Ash.Expr

    Ash.Query.filter(
      query,
      Ash.Expr.expr(occurred_at >= ^since and occurred_at <= ^until_)
    )
  end

  defp apply_ash_events_action_filter(query, nil), do: query
  defp apply_ash_events_action_filter(query, []), do: query

  defp apply_ash_events_action_filter(query, types) when is_list(types) do
    require Ash.Expr

    atom_types = Enum.map(types, &safe_to_atom/1)

    Ash.Query.filter(query, Ash.Expr.expr(action_type in ^atom_types))
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp apply_time_filters(query, nil, nil), do: query

  defp apply_time_filters(query, since, nil) do
    require Ash.Expr

    Ash.Query.filter(query, Ash.Expr.expr(version_inserted_at >= ^since))
  end

  defp apply_time_filters(query, nil, until_) do
    require Ash.Expr

    Ash.Query.filter(query, Ash.Expr.expr(version_inserted_at <= ^until_))
  end

  defp apply_time_filters(query, since, until_) do
    require Ash.Expr

    Ash.Query.filter(
      query,
      Ash.Expr.expr(version_inserted_at >= ^since and version_inserted_at <= ^until_)
    )
  end

  defp apply_action_filter(query, nil), do: query
  defp apply_action_filter(query, []), do: query

  defp apply_action_filter(query, types) when is_list(types) do
    require Ash.Expr

    Ash.Query.filter(query, Ash.Expr.expr(version_action_type in ^types))
  end

  ## Actor filter (post-merge)

  @doc false
  def __matches_actor__?(entry, actor_id), do: matches_actor?(entry, actor_id)

  defp matches_actor?(_entry, nil), do: true
  defp matches_actor?(_entry, ""), do: true

  defp matches_actor?(%{version: version}, actor_id) do
    inputs = version.version_action_inputs || %{}
    actor_id_str = to_string(actor_id)
    actor = Map.get(inputs, "actor")

    matches_actor_value?(actor, actor_id_str) or
      matches_actor_value?(nested(actor, "id"), actor_id_str) or
      matches_actor_value?(nested(actor, "email"), actor_id_str) or
      matches_actor_value?(Map.get(inputs, "actor_id"), actor_id_str)
  end

  defp nested(map, key) when is_map(map), do: Map.get(map, key)
  defp nested(_, _), do: nil

  defp matches_actor_value?(value, actor_id_str) do
    case value do
      ^actor_id_str -> true
      v when is_binary(v) -> v == actor_id_str
      v when is_atom(v) -> Atom.to_string(v) == actor_id_str
      _ -> false
    end
  end
end
