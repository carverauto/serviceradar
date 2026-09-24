defmodule ServiceRadar.Plugins.AssignmentOwner do
  @moduledoc """
  Who owns an enabled plugin assignment, for the one-enabled-assignment rule.

  An agent may hold several enabled assignments for the same plugin when they
  belong to different credential rules: for example an inventory producer
  schedule and an interface config check schedule of the same package.

  Ownership is derived from `policy_id`:

    * `nil` - a manual assignment.
    * `network-credential-rule:<rule id>[:<suffix>]` - owned by that credential
      rule. The suffix (purpose, provisioning kind) is ignored, so a rule whose
      policy id drifted still conflicts with its own older row and the
      reconciler adopts that row instead of leaving an orphan.
    * any other policy id - owned by that policy id.

  Only rule-owned assignments of different rules are allowed to coexist; see
  `conflict?/2`.
  """

  @rule_prefix "network-credential-rule:"

  @type owner :: :manual | {:rule, String.t()} | {:policy, String.t()}

  @spec owner(String.t() | nil) :: owner()
  def owner(nil), do: :manual

  def owner(policy_id) when is_binary(policy_id) do
    case String.trim(policy_id) do
      "" ->
        :manual

      @rule_prefix <> rest ->
        case rest |> String.split(":", parts: 2) |> hd() do
          "" -> {:policy, policy_id}
          rule_id -> {:rule, rule_id}
        end

      trimmed ->
        {:policy, trimmed}
    end
  end

  @doc """
  Whether two enabled assignments for the same plugin and agent collide.

  Only two credential-rule-owned assignments for different rules may coexist.
  Every other pairing (manual rows, arbitrary policy ids) keeps the original
  rule: any two enabled assignments collide.
  """
  @spec conflict?(String.t() | nil, String.t() | nil) :: boolean()
  def conflict?(policy_a, policy_b) do
    case {owner(policy_a), owner(policy_b)} do
      {{:rule, rule_a}, {:rule, rule_b}} -> rule_a == rule_b
      _ -> true
    end
  end

  @doc """
  Whether the reconciler may adopt `existing` for `policy_id`: never another
  credential rule's assignment, otherwise as before.
  """
  @spec same_owner?(String.t() | nil, String.t() | nil) :: boolean()
  def same_owner?(policy_id, existing_policy_id), do: conflict?(policy_id, existing_policy_id)
end
