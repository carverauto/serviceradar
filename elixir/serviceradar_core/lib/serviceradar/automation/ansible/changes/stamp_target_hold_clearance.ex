defmodule ServiceRadar.Automation.Ansible.Changes.StampTargetHoldClearance do
  @moduledoc false
  use Ash.Resource.Change

  alias ServiceRadar.AshContext

  @impl true
  def change(changeset, _opts, context) do
    actor = AshContext.actor(changeset) || AshContext.actor(context)
    evidence = Ash.Changeset.get_argument(changeset, :reconciliation_evidence)

    cond do
      Map.get(changeset.data, :active) != true ->
        Ash.Changeset.add_error(changeset,
          field: :active,
          message: "target hold is already cleared"
        )

      system_actor?(actor) ->
        Ash.Changeset.add_error(changeset,
          field: :cleared_by_principal_id,
          message: "a transport system actor cannot be the hold-clearance principal"
        )

      is_nil(actor_id(actor)) ->
        Ash.Changeset.add_error(changeset,
          field: :cleared_by_principal_id,
          message: "hold clearance requires an attributable principal"
        )

      not valid_evidence?(evidence) ->
        Ash.Changeset.add_error(changeset,
          field: :reconciliation_evidence,
          message:
            "must contain only recovery_method, evidence_digest, verified_at, and non-empty verification_ids"
        )

      true ->
        changeset
        |> Ash.Changeset.change_attribute(:active, false)
        |> Ash.Changeset.change_attribute(:cleared_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:cleared_by_principal_type, principal_type(actor))
        |> Ash.Changeset.change_attribute(:cleared_by_principal_id, actor_id(actor))
        |> Ash.Changeset.change_attribute(
          :clearance_approval_id,
          Ash.Changeset.get_argument(changeset, :approval_id)
        )
        |> Ash.Changeset.change_attribute(
          :clearance_policy_digest,
          Ash.Changeset.get_argument(changeset, :current_policy_digest)
        )
        |> Ash.Changeset.change_attribute(
          :clearance_evidence,
          stringify_keys(evidence)
        )
    end
  end

  defp system_actor?(%{role: :system}), do: true
  defp system_actor?(_actor), do: false

  defp actor_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_id(_actor), do: nil

  defp principal_type(%{principal_type: type}) when type in [:human, :service_principal], do: type
  defp principal_type(%{"principal_type" => "service_principal"}), do: :service_principal
  defp principal_type(_actor), do: :human

  defp valid_evidence?(evidence) when is_map(evidence) do
    evidence = stringify_keys(evidence)
    allowed_keys = ~w(recovery_method evidence_digest verified_at verification_ids)

    Map.keys(evidence) -- allowed_keys == [] and
      Map.get(evidence, "recovery_method") in ~w(fresh_ssh rollback_verified manual_recovery read_only_reconciliation) and
      non_empty_string?(Map.get(evidence, "evidence_digest")) and
      non_empty_string?(Map.get(evidence, "verified_at")) and
      non_empty_string_list?(Map.get(evidence, "verification_ids"))
  end

  defp valid_evidence?(_evidence), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != "" and byte_size(value) <= 512

  defp non_empty_string_list?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &non_empty_string?/1)

  defp non_empty_string_list?(_values), do: false

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
