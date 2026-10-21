defmodule ServiceRadar.Plugins.OwnedAssignmentRetraction do
  @moduledoc """
  Retracts plugin assignments whose owner no longer covers them.

  A policy-materialized assignment is owned by a credential rule
  (`policy_id` `network-credential-rule:<rule id>[:<purpose>]`) or by a plugin
  target policy (`policy_id` is the policy UUID). The periodic reconcilers only
  load enabled owners, so nothing they do ever reaches the assignments of an
  owner that was disabled, deleted, or narrowed. Those assignments are
  retracted here instead, in two ways:

    * **Owner lifecycle.** `ServiceRadar.Plugins.Changes.RetractOwnedAssignments`
      calls `retract_owner_assignments/4` and `retract_uncovered/3` from the
      owner's own update and destroy actions, inside their transaction, so every
      caller (UI, API, MCP) gets it. Each retraction records the acting operator
      and the reason `owner_disabled`, `owner_deleted` or
      `owner_scope_narrowed`.
    * **Pre-existing orphans.** An enabled assignment left behind by an owner
      that was disabled, deleted or narrowed before the lifecycle retraction
      existed is never disabled automatically. `list_orphaned_assignments/0`
      reports it and `retract_orphaned_assignments/2` retracts the ones an
      operator selects, with the reason `orphaned_owner_cleanup`.

  Coverage of a credential rule is its edge scope: the agent itself, the
  agent's gateway, or the assignment's authenticated partition. Coverage of a
  target policy is the set of agents its input definitions resolve to; that
  takes a query, so it is checked when the definitions change and is not part
  of the orphan report. As in `PolicyAssignmentReconciler`, a resolution with
  no rows means the targets are unknown and retracts nothing.

  Retraction alone would not hold: a reconcile that loaded an owner just before
  it was disabled or narrowed could re-enable the assignment right after the
  owner action retracted it, and no later reconcile would visit that owner
  again. `admit_enabled_assignment/3` closes that window. The assignment store
  of `PolicyAssignmentReconciler` calls it before writing an enabled row, in
  the same transaction, holding a share lock on the owner row. An owner update
  therefore either waits for that write and then retracts the new row, or
  commits first and the write is refused.

  Owners are always read as the system: an operator who may manage plugins but
  not credentials must not see a rule they cannot read as missing.
  """

  alias Ash.Notifier.Notification
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PolicyAssignmentPlanner
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @rule_policy_prefix "network-credential-rule:"

  @type owner_kind :: :credential_rule | :plugin_target_policy
  @type reason :: :owner_disabled | :owner_deleted | :owner_scope_narrowed
  @type owner_state :: :missing | :disabled | :out_of_scope

  @type orphan :: %{
          assignment_id: String.t(),
          agent_uid: String.t(),
          partition_id: String.t() | nil,
          plugin_id: String.t(),
          plugin_package_id: String.t(),
          package_name: String.t() | nil,
          package_version: String.t() | nil,
          policy_id: String.t(),
          owner_kind: owner_kind(),
          owner_id: String.t(),
          owner_name: String.t() | nil,
          owner_state: owner_state()
        }

  @doc """
  Retracts every enabled assignment owned by `owner`, recording `reason` and
  the actor whose action caused it.

  Returns the agent-config notifications of the retracted rows: the caller is
  inside the owner's transaction and must hand them back to Ash, which sends
  them after the commit.
  """
  @spec retract_owner_assignments(owner_kind(), map(), reason(), term()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def retract_owner_assignments(kind, owner, reason, actor) do
    with {:ok, rows} <- enabled_owned_assignments(kind, owner.id) do
      retract_rows(rows, reason, actor_label(actor), system_actor())
    end
  end

  @doc """
  Retracts the enabled assignments of an enabled owner whose agent the owner no
  longer covers, with the reason `owner_scope_narrowed`.

  A target policy's input definitions are resolved with `SRQLInputResolver`; a
  resolver error is returned and fails the owner action.
  """
  @spec retract_uncovered(owner_kind(), map(), term()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def retract_uncovered(:credential_rule, rule, actor) do
    with {:ok, rows} <- enabled_owned_assignments(:credential_rule, rule.id),
         {:ok, gateways} <- agent_gateways(rows, [rule]) do
      rows
      |> Enum.reject(&rule_covers?(rule, &1, gateways))
      |> retract_rows(:owner_scope_narrowed, actor_label(actor), system_actor())
    end
  end

  def retract_uncovered(:plugin_target_policy, policy, actor) do
    with {:ok, resolved} <- SRQLInputResolver.resolve(policy.input_definitions || []),
         {:ok, rows} <- enabled_owned_assignments(:plugin_target_policy, policy.id) do
      if resolved_row_count(resolved) == 0 do
        log_unresolved_hold(policy, rows)
        {:ok, []}
      else
        covered = PolicyAssignmentPlanner.resolved_agent_uids(resolved)

        rows
        |> Enum.reject(&MapSet.member?(covered, &1.agent_uid))
        |> retract_rows(:owner_scope_narrowed, actor_label(actor), system_actor())
      end
    end
  end

  @doc """
  Lists enabled assignments whose owner is missing, disabled, or (for a
  credential rule) no longer covers the agent.

  Assignments whose `policy_id` does not name a credential rule or a target
  policy, such as the AWX inventory sync, are not reported: their owner is
  another reconciler.
  """
  @spec list_orphaned_assignments() :: {:ok, [orphan()]} | {:error, term()}
  def list_orphaned_assignments do
    actor = system_actor()

    with {:ok, rows} <- read_enabled_policy_assignments(:all, nil),
         {:ok, orphans} <- orphans_among(rows, nil),
         {:ok, packages} <- load_packages(orphans, actor) do
      {:ok,
       orphans
       |> Enum.map(&to_orphan(&1, packages))
       |> Enum.sort_by(&{&1.owner_kind, &1.owner_id, &1.agent_uid, &1.plugin_id})}
    end
  end

  @doc """
  Retracts orphaned assignments selected by an operator, with the reason
  `orphaned_owner_cleanup`. `:all` retracts every current orphan.

  Eligibility is decided inside the transaction that retracts: the owners of
  the selected assignments are share-locked first and the assignment rows
  after them, the same order an owner action and the reconcilers' assignment
  store take, then the rows are classified again and only those that are still
  orphans are retracted. An id whose owner
  covers it again, or that a reconcile handed to another owner, is left alone,
  and the result counts the rows actually retracted. The update is authorized
  as `actor`; either every eligible row is retracted or none is.
  """
  @spec retract_orphaned_assignments([String.t()] | :all, term()) ::
          {:ok, %{retracted: non_neg_integer()}} | {:error, term()}
  def retract_orphaned_assignments(selection, actor) do
    fn ->
      with {:ok, candidates} <- read_enabled_policy_assignments(selection, nil),
           {:ok, rows} <- lock_owners_then_assignments(candidates),
           {:ok, orphans} <- orphans_among(rows, nil),
           orphan_rows = Enum.map(orphans, fn {row, _ref, _owner, _state} -> row end),
           {:ok, notifications} <-
             retract_rows(orphan_rows, :orphaned_owner_cleanup, actor_label(actor), actor) do
        {length(orphan_rows), notifications}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {count, notifications}} ->
        _unsent = Ash.Notifier.notify(notifications)
        {:ok, %{retracted: count}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether the owner named by `policy_id` still admits an enabled assignment on
  this agent and partition.

  Call it inside the transaction that writes the enabled row: it takes a share
  lock on the owner row, so an owner update cannot commit between this check
  and that write. A `policy_id` that names neither a credential rule nor a
  target policy is not this module's to judge and is admitted.
  """
  @spec admit_enabled_assignment(String.t() | nil, String.t(), String.t() | nil) ::
          :ok | {:error, {:assignment_owner_not_current, owner_state()}} | {:error, term()}
  def admit_enabled_assignment(policy_id, agent_uid, partition_id) do
    case OwnerReference.parse(policy_id) do
      {:ok, ref} ->
        row = %{agent_uid: agent_uid, partition_id: partition_id}

        case orphans_among([{row, ref}], "FOR SHARE") do
          {:ok, []} -> :ok
          {:ok, [{_row, _ref, _owner, state}]} -> {:error, {:assignment_owner_not_current, state}}
          {:error, reason} -> {:error, reason}
        end

      {:error, _not_an_owner} ->
        :ok
    end
  end

  defp retract_rows(rows, reason, disabled_by, actor) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      row
      |> Ash.Changeset.for_update(
        :retract,
        %{disabled_reason: reason, disabled_by: disabled_by},
        actor: actor
      )
      |> Ash.update(actor: actor, return_notifications?: true)
      |> case do
        {:ok, _row, notifications} -> {:cont, {:ok, notifications ++ acc}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # Called from the owner's own action, which already holds the owner row, so
  # the assignment rows are locked after it like everywhere else. `FOR UPDATE`
  # re-checks the filter on rows that changed while it waited: an assignment a
  # reconcile has just handed to another owner no longer matches and is left
  # to that owner.
  defp enabled_owned_assignments(kind, owner_id) do
    actor = system_actor()

    PluginAssignment
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(source == :policy and enabled == true)
    |> filter_owner(kind, to_string(owner_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read(actor: actor)
  end

  defp filter_owner(query, :plugin_target_policy, policy_id) do
    Ash.Query.filter(query, policy_id == ^policy_id)
  end

  # Rule ids are UUIDs, so the LIKE pattern carries no wildcard of its own.
  defp filter_owner(query, :credential_rule, rule_id) do
    base = @rule_policy_prefix <> rule_id
    purposes = base <> ":%"

    Ash.Query.filter(
      query,
      policy_id == ^base or fragment("? LIKE ?", policy_id, ^purposes)
    )
  end

  defp read_enabled_policy_assignments(selection, lock) do
    actor = system_actor()

    PluginAssignment
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(source == :policy and enabled == true and not is_nil(policy_id))
    |> filter_selection(selection)
    |> Ash.Query.sort(id: :asc)
    |> maybe_lock(lock)
    |> Ash.read(actor: actor)
  end

  defp filter_selection(query, :all), do: query

  defp filter_selection(query, ids) when is_list(ids) do
    ids = Enum.map(ids, &to_string/1)
    Ash.Query.filter(query, id in ^ids)
  end

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, lock), do: Ash.Query.lock(query, lock)

  # Owner rows before assignment rows, as everywhere else that takes both. An
  # assignment whose owner changed between the unlocked read and its lock is
  # skipped: its new owner is not locked.
  defp lock_owners_then_assignments([]), do: {:ok, []}

  defp lock_owners_then_assignments(candidates) do
    owned = owned_rows(candidates)
    actor = system_actor()
    owner_of = Map.new(candidates, &{&1.id, &1.policy_id})

    with {:ok, _rules} <-
           load_by_id(
             NetworkCredentialRule,
             owner_ids(owned, :credential_rule),
             actor,
             "FOR SHARE"
           ),
         {:ok, _policies} <-
           load_by_id(
             PluginTargetPolicy,
             owner_ids(owned, :plugin_target_policy),
             actor,
             "FOR SHARE"
           ),
         {:ok, rows} <-
           read_enabled_policy_assignments(Map.keys(owner_of), "FOR UPDATE") do
      {:ok, Enum.filter(rows, &(Map.get(owner_of, &1.id) == &1.policy_id))}
    end
  end

  # Classifies assignment rows (or `{row, owner_ref}` pairs) by their owner and
  # returns the ones the owner no longer admits, as `{row, ref, owner, state}`.
  # `lock` share-locks the owner rows for the caller's transaction.
  defp orphans_among(rows, lock) do
    owned = owned_rows(rows)
    actor = system_actor()

    with {:ok, rules} <-
           load_by_id(NetworkCredentialRule, owner_ids(owned, :credential_rule), actor, lock),
         {:ok, policies} <-
           load_by_id(PluginTargetPolicy, owner_ids(owned, :plugin_target_policy), actor, lock),
         {:ok, gateways} <- agent_gateways(owned_by(owned, :credential_rule), Map.values(rules)) do
      {:ok,
       Enum.flat_map(owned, fn {row, ref} ->
         owner = owner_record(ref, rules, policies)

         case owner_state(ref.kind, owner, row, gateways) do
           :covered -> []
           state -> [{row, ref, owner, state}]
         end
       end)}
    end
  end

  defp owned_rows(rows) do
    Enum.flat_map(rows, fn
      {row, ref} ->
        [{row, ref}]

      row ->
        case OwnerReference.parse(row.policy_id) do
          {:ok, ref} -> [{row, ref}]
          {:error, _not_an_owner} -> []
        end
    end)
  end

  defp owned_by(owned, kind) do
    for {row, %{kind: ^kind}} <- owned, do: row
  end

  defp owner_ids(owned, kind) do
    owned
    |> Enum.filter(fn {_row, ref} -> ref.kind == kind end)
    |> Enum.map(fn {_row, ref} -> ref.id end)
    |> Enum.uniq()
  end

  defp load_by_id(_resource, [], _actor, _lock), do: {:ok, %{}}

  defp load_by_id(resource, ids, actor, lock) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> maybe_lock(lock)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, records} -> {:ok, Map.new(records, &{to_string(&1.id), &1})}
      {:error, error} -> {:error, error}
    end
  end

  defp owner_record(%{kind: :credential_rule, id: id}, rules, _policies), do: Map.get(rules, id)

  defp owner_record(%{kind: :plugin_target_policy, id: id}, _rules, policies),
    do: Map.get(policies, id)

  defp owner_state(_kind, nil, _row, _gateways), do: :missing
  defp owner_state(_kind, %{enabled: false}, _row, _gateways), do: :disabled

  defp owner_state(:credential_rule, rule, row, gateways) do
    if rule_covers?(rule, row, gateways), do: :covered, else: :out_of_scope
  end

  defp owner_state(:plugin_target_policy, _policy, _row, _gateways), do: :covered

  # Mirrors the scopes the credential-rule materializer selects rules by: the
  # agent itself, its gateway, and its authenticated partition.
  defp rule_covers?(%{scope_type: :agent, scope_value: value}, row, _gateways),
    do: row.agent_uid == value

  defp rule_covers?(%{scope_type: :partition, scope_value: value}, row, _gateways),
    do: row.partition_id == value

  defp rule_covers?(%{scope_type: :gateway, scope_value: value}, row, gateways),
    do: Map.get(gateways, row.agent_uid) == value

  defp rule_covers?(_rule, _row, _gateways), do: false

  # Only a gateway-scoped rule needs the agent's gateway.
  defp agent_gateways(rows, rules) do
    agent_uids =
      if Enum.any?(rules, &(&1.scope_type == :gateway)) do
        rows |> Enum.map(& &1.agent_uid) |> Enum.uniq()
      else
        []
      end

    load_agent_gateways(agent_uids)
  end

  defp load_agent_gateways([]), do: {:ok, %{}}

  defp load_agent_gateways(agent_uids) do
    actor = system_actor()

    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^agent_uids)
    |> Ash.Query.select([:uid, :gateway_id])
    |> Ash.read(actor: actor, page: false)
    |> case do
      {:ok, agents} -> {:ok, Map.new(agents, &{&1.uid, &1.gateway_id})}
      {:error, error} -> {:error, error}
    end
  end

  defp load_packages([], _actor), do: {:ok, %{}}

  defp load_packages(orphans, actor) do
    ids =
      orphans
      |> Enum.map(fn {row, _ref, _owner, _state} -> row.plugin_package_id end)
      |> Enum.uniq()

    PluginPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :name, :version])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, packages} -> {:ok, Map.new(packages, &{to_string(&1.id), &1})}
      {:error, error} -> {:error, error}
    end
  end

  defp to_orphan({row, ref, owner, state}, packages) do
    package = Map.get(packages, to_string(row.plugin_package_id))

    %{
      assignment_id: to_string(row.id),
      agent_uid: row.agent_uid,
      partition_id: row.partition_id,
      plugin_id: row.plugin_id,
      plugin_package_id: to_string(row.plugin_package_id),
      package_name: package && package.name,
      package_version: package && package.version,
      policy_id: row.policy_id,
      owner_kind: ref.kind,
      owner_id: ref.id,
      owner_name: owner && owner.name,
      owner_state: state
    }
  end

  defp resolved_row_count(resolved_inputs) do
    Enum.reduce(resolved_inputs, 0, fn input, count ->
      count + length(ValueUtils.list_value(input, [:rows, "rows"]) || [])
    end)
  end

  defp log_unresolved_hold(_policy, []), do: :ok

  defp log_unresolved_hold(policy, rows) do
    Logger.warning(
      "Plugin target policy #{policy.id} input definitions resolved no rows; keeping " <>
        "#{length(rows)} enabled assignment(s) instead of retracting them " <>
        "(reason: targets_unresolved)",
      policy_id: to_string(policy.id),
      reason: :targets_unresolved
    )
  end

  defp actor_label(actor) when is_map(actor) do
    case Map.get(actor, :id) || Map.get(actor, :email) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp actor_label(_actor), do: nil

  defp system_actor, do: SystemActor.system(:plugin_owned_assignment_retraction)
end
