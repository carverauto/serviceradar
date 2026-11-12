defmodule ServiceRadar.Automation.Ansible.Changes.ReleaseAwxHostMembershipQuarantine do
  @moduledoc """
  Compare-and-swap release of one quarantined AWX host membership.

  The caller (`AwxMembershipQuarantineRelease`) has already evaluated current
  device inventory under the controller's observation lock and passes the
  outcome as arguments. This change only checks the principal and the shape of
  that outcome, and filters the write to the exact quarantined row the reviewer
  saw. It reads no original data, so it runs atomically; a row that changed
  since it was read matches no row and the update fails.

  The outcome is `proposed` with exactly one device or `unlinked` with none.
  `approved` is not a permitted argument value.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AshContext

  require Ash.Expr

  @source_evidence_keys MapSet.new(~w(
    kind
    controller_id
    inventory_id
    awx_host_id
    matching_device_uids
    match_count
  ))

  @impl true
  def change(changeset, _opts, context) do
    actor = AshContext.actor(changeset) || AshContext.actor(context)

    with :ok <- require_human(actor),
         :ok <- require_consistent_outcome(changeset) do
      release(changeset)
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp require_human(%{role: :system}),
    do: {:error, :link_disposition, "AWX quarantine release requires a human principal"}

  defp require_human(%{principal_type: type}) when type not in [:human, "human"],
    do: {:error, :link_disposition, "AWX quarantine release requires a human principal"}

  defp require_human(%{"principal_type" => type}) when type not in [:human, "human"],
    do: {:error, :link_disposition, "AWX quarantine release requires a human principal"}

  defp require_human(actor) do
    case actor_id(actor) do
      id when is_binary(id) and id != "" -> :ok
      _ -> {:error, :link_disposition, "AWX quarantine release requires an attributable human"}
    end
  end

  defp require_consistent_outcome(changeset) do
    disposition = Ash.Changeset.get_argument(changeset, :released_link_disposition)
    device_uid = Ash.Changeset.get_argument(changeset, :canonical_device_uid)
    evidence = Ash.Changeset.get_argument(changeset, :released_link_evidence)

    expected_matches =
      case {disposition, device_uid} do
        {:proposed, uid} when is_binary(uid) -> [uid]
        {:unlinked, nil} -> []
        _ -> :invalid
      end

    if expected_matches != :invalid and source_evidence?(changeset, evidence, expected_matches) do
      :ok
    else
      {:error, :released_link_evidence,
       "does not prove one device for proposed or no device for unlinked"}
    end
  end

  defp source_evidence?(changeset, evidence, matches) when is_map(evidence) do
    MapSet.new(Map.keys(evidence)) == @source_evidence_keys and
      evidence["kind"] == "stored_awx_source_tuple" and
      evidence["controller_id"] ==
        to_string(Ash.Changeset.get_argument(changeset, :controller_id)) and
      evidence["inventory_id"] == Ash.Changeset.get_argument(changeset, :inventory_id) and
      evidence["awx_host_id"] == Ash.Changeset.get_argument(changeset, :awx_host_id) and
      evidence["matching_device_uids"] == matches and
      evidence["match_count"] == length(matches)
  end

  defp source_evidence?(_changeset, _evidence, _matches), do: false

  defp release(changeset) do
    controller_id = Ash.Changeset.get_argument(changeset, :controller_id)
    inventory_id = Ash.Changeset.get_argument(changeset, :inventory_id)
    awx_host_id = Ash.Changeset.get_argument(changeset, :awx_host_id)
    source_generation = Ash.Changeset.get_argument(changeset, :source_generation)
    source_fingerprint = Ash.Changeset.get_argument(changeset, :source_fingerprint)
    expected_evidence = Ash.Changeset.get_argument(changeset, :expected_link_evidence)

    changeset
    |> Ash.Changeset.filter(
      Ash.Expr.expr(
        controller_id == ^controller_id and
          inventory_id == ^inventory_id and
          awx_host_id == ^awx_host_id and
          source_generation == ^source_generation and
          source_fingerprint == ^source_fingerprint and
          current == true and is_nil(expired_at) and
          link_disposition == :quarantined and link_evidence == ^expected_evidence
      )
    )
    |> Ash.Changeset.force_change_attributes(%{
      link_disposition: Ash.Changeset.get_argument(changeset, :released_link_disposition),
      canonical_device_uid: Ash.Changeset.get_argument(changeset, :canonical_device_uid),
      link_evidence: Ash.Changeset.get_argument(changeset, :released_link_evidence),
      quarantine_reason: nil,
      quarantined_at: nil
    })
  end

  defp actor_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_id(_actor), do: nil
end
