defmodule ServiceRadar.Inventory.Identity.MergePolicy do
  @moduledoc """
  Evidence policy for automatic merges: which identifier-match sets are
  eligible (never agent_id-only, MAC-only, or medium-confidence-only)
  and blocked-merge telemetry.
  """

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

  def emit_blocked_merge_telemetry(blocked_reason, device_ids, identifiers) do
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
  end
end
