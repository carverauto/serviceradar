defmodule ServiceRadar.Security.AuditHistory do
  @moduledoc """
  Cross-resource read surface over the AshPaperTrail `<Resource>.Version`
  sibling modules. Returns a merged, time-ordered list of version
  rows from every resource in a configurable allow-list so the
  Settings → Audit → History LiveView can render one timeline.

  The allow-list lives at
  `config :serviceradar_core, #{__MODULE__}, resources: [...]`.
  Operators may include or exclude specific resources without
  touching this module.

  Per-resource Ash policies still gate the version reads — calling
  `list_recent/2` with an actor that can't read a particular
  resource's versions transparently drops those rows from the
  result. Pagination keeps its shape because the merge happens
  after the per-resource reads.
  """

  require Ash.Query

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
    resource_types = Keyword.get(opts, :resource_types, resources())
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

    resource_types
    |> Enum.filter(&(&1 in resources()))
    |> Enum.flat_map(&read_versions(&1, actor, since, until_, action_types, per_source))
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
          Enum.map(versions, &%{resource: resource, version: &1})

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
