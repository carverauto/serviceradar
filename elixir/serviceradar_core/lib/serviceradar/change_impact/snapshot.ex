defmodule ServiceRadar.ChangeImpact.Snapshot do
  @moduledoc """
  NMS-neutral snapshot for scrith's extension contract.

  Field names are assets, links, prefixes, changes, telemetry — not
  ServiceRadar crate paths. This module does not implement ChangeImpact
  RPC, Ethos, or postpone/sequence verdicts.
  """

  @spec from_parts(keyword()) :: map()
  def from_parts(opts) when is_list(opts) do
    %{
      "assets" => Keyword.get(opts, :assets, []),
      "links" => Keyword.get(opts, :links, []),
      "prefixes" => Keyword.get(opts, :prefixes, []),
      "changes" => Keyword.get(opts, :changes, []),
      "telemetry" => Keyword.get(opts, :telemetry, [])
    }
  end

  @spec change_node(map()) :: map()
  def change_node(change) when is_map(change) do
    payload = ServiceRadar.NetworkChanges.Projector.graph_payload(change)

    %{
      "id" => payload.id,
      "kind" => payload.kind,
      "status" => payload.status,
      "source" => payload.source,
      "window_start" => payload.window_start,
      "window_end" => payload.window_end,
      "affects" => payload.affects_prefix_cidrs ++ payload.affects_device_ids
    }
  end
end
