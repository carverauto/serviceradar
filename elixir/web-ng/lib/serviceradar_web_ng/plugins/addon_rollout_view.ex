defmodule ServiceRadarWebNG.Plugins.AddonRolloutView do
  @moduledoc """
  Operator-facing presentation for native add-on rollouts.

  The durable rollout row keys a profile or a direct assignment by UUID. That
  identifier is an implementation detail, not an agent or a device. This module
  turns the Ash records into names, progress, and a "what happened" sentence.
  """

  # Operator still has a decision (Resume / Cancel). Terminal Failed/Rolled back
  # attempts belong under "Show finished", not the open-jobs list.
  @attention_states [:paused, :rolling_back]
  @active_states [:pending, :running, :paused, :rolling_back]

  @state_labels %{
    pending: "Waiting to start",
    running: "In progress",
    paused: "Paused",
    rolling_back: "Rolling back",
    completed: "Completed",
    failed: "Failed",
    canceled: "Canceled",
    rolled_back: "Rolled back",
    superseded: "Superseded"
  }

  @target_state_labels %{
    pending: "Queued",
    waiting_health: "Waiting for health",
    healthy_soak: "Soaking",
    succeeded: "Healthy on candidate",
    promoted: "Promoted",
    failed: "Failed",
    rollback_pending: "Rolling back",
    rolled_back: "Rolled back",
    excluded: "Skipped",
    canceled: "Canceled"
  }

  @classification_labels %{
    eligible: "Eligible",
    unavailable: "Unavailable",
    incompatible: "Incompatible",
    overridden: "Overridden",
    unresolved: "Unresolved"
  }

  @trigger_labels %{
    track_latest: "Automatic",
    manual: "Manual",
    retry: "Retry"
  }

  @reason_labels %{
    "runtime_reported_unhealthy" => "runtime reported unhealthy",
    "desired_package_not_approved" => "desired package is not approved",
    "desired_state_not_converged" => "desired state did not converge",
    "candidate_health_timeout" => "candidate never reported healthy in time",
    "candidate_reported_unhealthy" => "candidate reported unhealthy",
    "rollback_recovery_unverified" => "rollback recovery is unverified",
    "waiting_for_fresh_candidate_health" => "waiting for a fresh healthy report",
    "fleet_already_on_candidate" => "fleet is already on this candidate",
    "operator_canceled" => "canceled by an operator"
  }

  @type lookups :: %{
          optional(:profiles) => map(),
          optional(:assignments) => map(),
          optional(:agents) => map()
        }

  @spec present(map() | struct(), lookups()) :: map()
  def present(rollout, lookups \\ %{}) do
    lookups = %{
      profiles: Map.get(lookups, :profiles, %{}),
      assignments: Map.get(lookups, :assignments, %{}),
      agents: Map.get(lookups, :agents, %{})
    }

    targets =
      rollout
      |> field(:targets)
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&present_target(&1, lookups.agents))

    previous_version = package_version(field(rollout, :previous_package))
    candidate_version = package_version(field(rollout, :candidate_package))
    addon_id = to_string(field(rollout, :addon_id) || "")
    state = normalize_atom(field(rollout, :state))
    blocked_reason = present_string(field(rollout, :blocked_reason))
    error = present_string(field(rollout, :error))
    scope = scope(rollout, targets, lookups)

    %{
      id: field(rollout, :id),
      addon_id: addon_id,
      addon_name: package_name(field(rollout, :candidate_package), addon_id),
      previous_version: previous_version,
      candidate_version: candidate_version,
      state: state,
      state_label: state_label(state),
      trigger: normalize_atom(field(rollout, :trigger)),
      trigger_label: trigger_label(field(rollout, :trigger)),
      scope_kind: scope.kind,
      scope_label: scope.label,
      scope_caption: scope.caption,
      scope_href: scope.href,
      summary:
        summary(%{
          state: state,
          blocked_reason: blocked_reason,
          error: error,
          previous_version: previous_version,
          candidate_version: candidate_version,
          targets: targets,
          scope_kind: scope.kind
        }),
      progress_label: progress_label(targets, previous_version, candidate_version),
      blocked_reason: blocked_reason,
      reason_label: reason_label(blocked_reason),
      error: error,
      attention?: state in @attention_states,
      active?: state in @active_states,
      sort_rank: sort_rank(state),
      targets: targets,
      started_at: field(rollout, :started_at),
      paused_at: field(rollout, :paused_at),
      completed_at: field(rollout, :completed_at)
    }
  end

  @spec state_label(atom() | String.t() | nil) :: String.t()
  def state_label(state) do
    atom = normalize_atom(state)
    Map.get(@state_labels, atom, humanize(state))
  end

  @spec target_state_label(atom() | String.t() | nil) :: String.t()
  def target_state_label(state) do
    atom = normalize_atom(state)
    Map.get(@target_state_labels, atom, humanize(state))
  end

  @spec reason_label(String.t() | atom() | nil) :: String.t() | nil
  def reason_label(nil), do: nil
  def reason_label(""), do: nil

  def reason_label(reason) do
    key = to_string(reason)

    case String.trim(key) do
      "" -> nil
      trimmed -> Map.get(@reason_labels, trimmed, humanize(trimmed))
    end
  end

  @spec trigger_label(atom() | String.t() | nil) :: String.t()
  def trigger_label(trigger) do
    atom = normalize_atom(trigger)
    Map.get(@trigger_labels, atom, humanize(trigger))
  end

  @spec fleet_health(map()) :: %{
          title: String.t(),
          detail: String.t(),
          action: :review_rollout | :open_package | :inspect_runtime | nil,
          action_label: String.t() | nil
        }
  def fleet_health(row) when is_map(row) do
    category = field(row, :category)
    reason = present_string(field(row, :reason_code))
    attempted = attempted_version(row)
    current = current_version(row)

    case {category, reason} do
      {:action_required, "candidate_health_timeout"} ->
        action(
          "Update blocked",
          "A canary for #{attempted} did not pass health in time. This agent is running #{current}. Cancel or resume the paused rollout.",
          :review_rollout
        )

      {:action_required, "candidate_reported_unhealthy"} ->
        action(
          "Update blocked",
          "A canary for #{attempted} reported unhealthy. This agent is running #{current}. Cancel or resume the paused rollout.",
          :review_rollout
        )

      {:action_required, "rollback_recovery_unverified"} ->
        action(
          "Update blocked",
          "We could not confirm this agent recovered on #{current} after #{attempted} failed.",
          :review_rollout
        )

      {:action_required, reason} when reason in ["rollout_failed", "rollout_target_incompatible"] ->
        action(
          "Update blocked",
          "The automatic update to #{attempted} did not finish. This agent is on #{current}.",
          :review_rollout
        )

      {:action_required, "desired_package_not_approved"} ->
        action(
          "Package not approved",
          "The assigned package cannot be delivered until an operator approves it.",
          :open_package
        )

      {:action_required, "runtime_reported_unhealthy"} ->
        action(
          "Runtime unhealthy",
          present_string(field(row, :degradation_reason)) ||
            "This add-on reported itself unhealthy.",
          :inspect_runtime
        )

      {:action_required, "desired_state_not_converged"} ->
        %{
          title: "Not converged",
          detail: "Assigned #{field(row, :assigned_version) || "a newer package"} but this agent is still on #{current}.",
          action: nil,
          action_label: nil
        }

      {:action_required, _} ->
        action(
          "Needs attention",
          reason_label(reason) || "This add-on needs an operator decision.",
          if(field(row, :rollout_id), do: :review_rollout)
        )

      {:updating, _} ->
        action(
          "Updating",
          "A health-gated update to #{attempted} is in progress on this agent.",
          :review_rollout
        )

      {:healthy, _} ->
        %{
          title: "Healthy",
          detail: "Desired version is running.",
          action: nil,
          action_label: nil
        }

      {:unavailable, reason} ->
        %{
          title: "Unavailable",
          detail: reason_label(reason) || "No recent runtime evidence from this agent.",
          action: nil,
          action_label: nil
        }

      {:expected_inactive, _} ->
        %{
          title: "Expected idle",
          detail: "This add-on is not supposed to be running right now.",
          action: nil,
          action_label: nil
        }

      {:observed_only, _} ->
        %{
          title: "Observed only",
          detail: "Running on the agent, but nothing assigns this add-on.",
          action: nil,
          action_label: nil
        }

      _other ->
        %{
          title: humanize(category),
          detail: reason_label(reason) || "",
          action: nil,
          action_label: nil
        }
    end
  end

  @spec agent_label(map() | struct() | nil, String.t() | nil) :: String.t()
  def agent_label(agent, fallback_uid) do
    name = present_string(field(agent, :name)) || present_string(field(agent, :host))
    uid = present_string(field(agent, :uid)) || present_string(fallback_uid)

    cond do
      name && uid -> "#{name} (#{uid})"
      name -> name
      uid -> uid
      true -> "Unknown agent"
    end
  end

  defp present_target(target, agents) do
    agent_uid = present_string(field(target, :agent_uid))
    agent = agent_uid && Map.get(agents, agent_uid)
    display_name = present_string(field(agent, :name)) || present_string(field(agent, :host))
    batch_index = field(target, :batch_index) || 0

    %{
      id: field(target, :id),
      agent_uid: agent_uid,
      agent_name: display_name || agent_uid || "Unknown agent",
      agent_label: agent_label(agent, agent_uid),
      agent_href: if(agent_uid, do: "/agents/#{agent_uid}"),
      batch_index: batch_index,
      batch_label: batch_label(batch_index),
      classification: field(target, :classification),
      classification_label: classification_label(field(target, :classification)),
      state: normalize_atom(field(target, :state)),
      state_label: target_state_label(field(target, :state)),
      reason_code: present_string(field(target, :reason_code)),
      reason_label: reason_label(field(target, :reason_code)),
      error: present_string(field(target, :error)),
      health_observed_at: field(target, :health_observed_at),
      healthy_since: field(target, :healthy_since),
      rollback_started_at: field(target, :rollback_started_at),
      override_applied_at: field(target, :override_applied_at)
    }
  end

  defp scope(rollout, targets, lookups) do
    case normalize_atom(field(rollout, :source_type)) do
      :profile ->
        profile = Map.get(lookups.profiles, field(rollout, :source_id))
        name = present_string(field(profile, :name)) || "Deleted profile"
        count = length(targets)

        %{
          kind: :profile,
          label: name,
          caption: "Add-on profile · #{count} #{pluralize(count, "agent")}",
          href: nil
        }

      :assignment ->
        assignment = Map.get(lookups.assignments, field(rollout, :source_id))
        uid = present_string(field(assignment, :agent_uid)) || notable_agent_uid(targets)
        agent = uid && Map.get(lookups.agents, uid)
        name = present_string(field(agent, :name)) || present_string(field(agent, :host))

        %{
          kind: :agent,
          label: name || uid || "Unknown agent",
          caption:
            if(name && uid,
              do: "Direct assignment · #{uid}",
              else: "Direct assignment to this agent"
            ),
          href: if(uid, do: "/agents/#{uid}")
        }

      _other ->
        %{kind: :unknown, label: "Unknown source", caption: "Not an agent or device id", href: nil}
    end
  end

  defp summary(ctx) do
    agent = notable_agent_name(ctx.targets)
    previous = ctx.previous_version
    candidate = ctx.candidate_version
    fleet? = ctx.scope_kind == :profile

    cond do
      ctx.blocked_reason == "candidate_health_timeout" and ctx.state in [:failed, :rolled_back] ->
        "#{agent} never reported healthy on #{candidate} in time. That attempt stopped; agents on this rollout were left on #{previous}."

      ctx.blocked_reason == "candidate_health_timeout" ->
        "#{agent} never reported healthy on #{candidate} before the health check timed out. We rolled that agent back to #{previous} and paused so #{rest_of_fleet(fleet?)}."

      ctx.blocked_reason == "candidate_reported_unhealthy" and ctx.state in [:failed, :rolled_back] ->
        "#{agent} reported #{candidate} as unhealthy. That attempt stopped; agents on this rollout were left on #{previous}."

      ctx.blocked_reason == "candidate_reported_unhealthy" ->
        "#{agent} reported #{candidate} as unhealthy. We rolled that agent back to #{previous} and paused so #{rest_of_fleet(fleet?)}."

      ctx.blocked_reason == "rollback_recovery_unverified" ->
        "We tried to roll #{agent} back to #{previous} after the candidate failed, but could not confirm it recovered."

      ctx.blocked_reason == "fleet_already_on_candidate" ->
        "Every targeted agent is already on #{candidate}, so this rollout has nothing left to do."

      ctx.blocked_reason == "operator_canceled" ->
        "An operator canceled this rollout."

      ctx.blocked_reason == "desired_package_not_approved" ->
        "The candidate package is not approved, so this rollout cannot continue."

      ctx.blocked_reason ->
        "#{reason_label(ctx.blocked_reason)}."

      ctx.state == :paused and is_binary(ctx.error) ->
        "The rollout paused because a batch could not start: #{ctx.error}"

      ctx.state == :paused ->
        "An operator paused this rollout. Remaining agents stay on #{previous} until you resume, roll back, or cancel."

      ctx.state == :running ->
        "Updating #{length(ctx.targets)} #{pluralize(length(ctx.targets), "agent")} from #{previous} to #{candidate}. A canary must stay healthy before later batches advance."

      ctx.state == :pending ->
        "Waiting to start the update from #{previous} to #{candidate}."

      ctx.state == :completed ->
        "All targeted agents are on #{candidate}."

      ctx.state == :failed ->
        "This rollout did not finish. Failed agents were left on #{previous}."

      ctx.state == :rolled_back ->
        "The candidate did not stick. Targeted agents are back on #{previous}."

      ctx.state == :rolling_back ->
        "Rolling #{agent} back to #{previous} after the candidate failed."

      ctx.state == :canceled ->
        "This rollout was canceled. Desired state stays on the last stable package."

      ctx.state == :superseded ->
        "The fleet reached #{candidate} some other way, so this rollout has nothing left to do."

      true ->
        "Update from #{previous} to #{candidate}."
    end
  end

  defp progress_label(targets, previous, candidate) do
    total = length(targets)

    if total == 0 do
      "No agents targeted"
    else
      on_candidate =
        Enum.count(targets, &(&1.state in [:succeeded, :promoted]))

      held = Enum.count(targets, &(&1.state == :rolled_back))
      waiting = Enum.count(targets, &(&1.state in [:waiting_health, :healthy_soak]))

      [
        "#{on_candidate} of #{total} #{pluralize(total, "agent")} on #{candidate}",
        if(held > 0, do: "#{held} held on #{previous}"),
        if(waiting > 0, do: "#{waiting} waiting for health")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
    end
  end

  defp notable_agent_name(targets) do
    target =
      Enum.find(targets, &(&1.state in [:failed, :rollback_pending, :rolled_back])) ||
        List.first(targets)

    cond do
      is_nil(target) -> "An agent"
      is_binary(target.agent_name) and target.agent_name != "" -> target.agent_name
      is_binary(target.agent_uid) and target.agent_uid != "" -> target.agent_uid
      true -> "An agent"
    end
  end

  defp notable_agent_uid(targets) do
    targets
    |> List.first()
    |> case do
      %{agent_uid: uid} -> uid
      _ -> nil
    end
  end

  defp rest_of_fleet(true), do: "the rest of the profile stays on the last good version"
  defp rest_of_fleet(false), do: "this agent stays on the last good version"

  defp classification_label(value) do
    atom = normalize_atom(value)
    Map.get(@classification_labels, atom, humanize(value))
  end

  defp batch_label(0), do: "Canary"
  defp batch_label(index) when is_integer(index), do: "Batch #{index + 1}"
  defp batch_label(_), do: "Batch"

  defp sort_rank(state) when state in @attention_states, do: 0
  defp sort_rank(state) when state in [:running, :pending], do: 1
  defp sort_rank(_state), do: 2

  defp action(title, detail, nil) do
    %{title: title, detail: detail, action: nil, action_label: nil}
  end

  defp action(title, detail, :review_rollout) do
    %{title: title, detail: detail, action: :review_rollout, action_label: "Review rollout"}
  end

  defp action(title, detail, :open_package) do
    %{title: title, detail: detail, action: :open_package, action_label: "Open package"}
  end

  defp action(title, detail, :inspect_runtime) do
    %{title: title, detail: detail, action: :inspect_runtime, action_label: "View diagnostics"}
  end

  defp attempted_version(row) do
    field(row, :rollout_candidate_version) ||
      case {present_string(field(row, :assigned_version)), present_string(field(row, :running_version))} do
        {assigned, running} when is_binary(assigned) and assigned != running -> assigned
        _ -> field(row, :latest_approved_version) || field(row, :assigned_version) || "the candidate"
      end
  end

  defp current_version(row) do
    field(row, :running_version) || field(row, :assigned_version) || "the previous version"
  end

  defp package_version(%{version: version}) when is_binary(version) and version != "", do: version
  defp package_version(_), do: "unknown"

  defp package_name(%{name: name}, _fallback) when is_binary(name) and name != "", do: name
  defp package_name(_package, fallback) when is_binary(fallback) and fallback != "", do: fallback
  defp package_name(_package, _fallback), do: "Add-on"

  defp field(nil, _key), do: nil
  defp field(%{} = map, key), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_value), do: nil

  defp humanize(nil), do: ""

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
