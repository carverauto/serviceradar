defmodule ServiceRadar.Inventory.Sync.Risk do
  @moduledoc "Source risk contribution records for resolved updates."

  alias ServiceRadar.Inventory.Sync.Enrichment

  require Logger

  def build_source_risk_contribution_records(resolved_updates) do
    resolved_updates
    |> Enum.map(fn {update, device_id} ->
      metadata = update.metadata || %{}
      score = Enrichment.infer_risk_score(metadata)

      if is_integer(score) and score >= 0 do
        source = normalize_risk_source(update.source)

        %{
          device_uid: device_id,
          source: source,
          source_ref: "current",
          score: score,
          reason: "#{source} inventory risk",
          occurred_at: update.timestamp || update.last_seen_time || DateTime.utc_now(),
          metadata: %{
            "source" => source,
            "source_risk_level" => Enrichment.infer_risk_level(metadata),
            "ingested_by" => "sync_ingestor"
          }
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn contribution, acc ->
      key = {contribution.device_uid, contribution.source, contribution.source_ref}

      Map.update(acc, key, contribution, fn existing ->
        if contribution.score >= existing.score, do: contribution, else: existing
      end)
    end)
    |> Map.values()
  end

  defp normalize_risk_source(source) when source in [nil, ""], do: "unknown"

  defp normalize_risk_source(source) do
    source
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "unknown"
      value -> value
    end
  end
end
