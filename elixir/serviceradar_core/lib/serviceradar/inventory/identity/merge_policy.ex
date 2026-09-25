defmodule ServiceRadar.Inventory.Identity.MergePolicy do
  @moduledoc """
  Evidence policy for automatic merges: which identifier-match sets are
  eligible (never agent_id-only, MAC-only, or medium-confidence-only)
  and the record of each blocked merge.
  """

  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Mac

  # Merge only when there is at least one non-MAC strong identifier involved,
  # and the match set is not entirely medium-confidence MACs.
  def merge_allowed_for_matches?(matches) do
    not agent_id_only_matches?(matches) and not mac_only_matches?(matches) and
      not medium_confidence_only?(matches)
  end

  defp agent_id_only_matches?(matches) do
    Enum.any?(matches) and
      Enum.all?(matches, fn
        {:agent_id, _} -> true
        _ -> false
      end)
  end

  # MAC-only matches are too noisy (especially interface MACs observed by mapper)
  # and can collapse unrelated devices.
  defp mac_only_matches?(matches) do
    Enum.any?(matches) and
      Enum.all?(matches, fn
        {:mac, _} -> true
        _ -> false
      end)
  end

  # Returns true if the only shared identifiers that caused the conflict are
  # MAC addresses that are locally-administered (medium confidence).
  # Strong identifiers (agent_id, armis_id, etc.) are never medium-confidence.
  defp medium_confidence_only?(matches) do
    Enum.all?(matches, fn
      {:mac, %{value: value}} -> Mac.locally_administered_mac?(value)
      _ -> false
    end)
  end

  def blocked_merge_reason(matches) do
    cond do
      agent_id_only_matches?(matches) -> "agent_id_only_conflict"
      mac_only_matches?(matches) -> "mac_only_conflict"
      medium_confidence_only?(matches) -> "medium_confidence_only"
      true -> "policy_blocked"
    end
  end

  @doc """
  Records a merge `MergePolicy` refused: telemetry, plus a persisted identity decision
  (`:policy_block`) naming every device the match set joined, so the refusal can be reviewed.
  `source` names the calling path.
  """
  def record_blocked_merge(blocked_reason, device_ids, identifiers, source) do
    identifier_count =
      cond do
        is_list(identifiers) -> length(identifiers)
        is_map(identifiers) -> map_size(identifiers)
        true -> 0
      end

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :blocked],
      %{count: 1},
      %{
        reason: blocked_reason,
        device_count: length(device_ids),
        identifier_count: identifier_count
      }
    )

    DecisionLog.record(:policy_block, blocked_reason, device_ids,
      source: source,
      evidence: %{"identifiers" => identifier_evidence(identifiers)}
    )
  end

  # Match sets arrive as `{type, %{value:, device_id:}}` pairs (a map or a list of them), or as
  # already-flattened `%{type:, value:, device_id:}` maps.
  defp identifier_evidence(identifiers) when is_map(identifiers) or is_list(identifiers) do
    Enum.map(identifiers, fn
      {type, %{} = match} ->
        %{"type" => to_string(type), "value" => match[:value], "device_id" => match[:device_id]}

      %{} = match ->
        %{
          "type" => to_string(match[:type]),
          "value" => match[:value],
          "device_id" => match[:device_id]
        }

      other ->
        %{"value" => inspect(other)}
    end)
  end

  defp identifier_evidence(_identifiers), do: []
end
