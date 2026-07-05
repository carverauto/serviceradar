defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Projection do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection.Payload
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection.Policy

  @type projection_payload :: %{
          local_device_id: String.t(),
          local_device_ip: term(),
          neighbor_device_id: String.t(),
          local_interface_id: String.t(),
          neighbor_interface_id: String.t(),
          protocol: String.t(),
          local_if_name: term(),
          local_if_index: term(),
          neighbor_port_name: term(),
          neighbor_name: term(),
          neighbor_ip: term(),
          evidence_class: String.t(),
          relation_family: String.t(),
          confidence_tier: String.t(),
          confidence_score: number(),
          confidence_reason: String.t(),
          observed_at: String.t()
        }

  @doc """
  Pure classifier for mapper topology projection decisions.
  """
  @spec classify_projection(map()) ::
          {:ok,
           %{
             mode: :backbone | :auxiliary | :skip,
             relation: String.t() | nil,
             payload: projection_payload()
           }}
          | {:error, :missing_ids}
  def classify_projection(link) when is_map(link) do
    with {:ok, payload} <- build_link_payload(link) do
      case projection_mode(payload) do
        {:backbone, reason} ->
          {:ok, %{mode: :backbone, relation: "CONNECTS_TO", payload: payload, reason: reason}}

        {:auxiliary, reason} ->
          {:ok,
           %{
             mode: :auxiliary,
             relation: evidence_relation_type(payload),
             payload: payload,
             reason: reason
           }}

        {:skip, reason} ->
          {:ok, %{mode: :skip, relation: nil, payload: payload, reason: reason}}
      end
    end
  end

  @spec projection_diagnostics([map()]) :: %{
          accepted: map(),
          rejected: map(),
          total: non_neg_integer()
        }
  def projection_diagnostics(links) when is_list(links) do
    Enum.reduce(links, empty_projection_diagnostics(), fn link, diagnostics ->
      case projection_payload(link) do
        nil ->
          increment_diagnostic(diagnostics, :rejected, drop_reason(link) || :missing_ids)

        payload ->
          increment_projection_diagnostic(diagnostics, payload)
      end
    end)
  end

  @spec build_link_payload(map()) :: {:ok, projection_payload()} | {:error, :missing_ids}
  def build_link_payload(link) when is_map(link) do
    case projection_payload(link) do
      nil -> {:error, :missing_ids}
      payload -> {:ok, payload}
    end
  end

  defdelegate projection_payload(link),
    to: Payload

  defdelegate drop_reason(link),
    to: Payload

  defdelegate projection_mode(payload),
    to: Policy

  defdelegate evidence_relation_type(payload),
    to: Policy

  def empty_projection_diagnostics do
    %{accepted: %{}, rejected: %{}, total: 0}
  end

  def increment_projection_diagnostic(diagnostics, payload) do
    case projection_mode(payload) do
      {:backbone, reason} ->
        increment_diagnostic(diagnostics, :accepted, reason)

      {:auxiliary, reason} ->
        increment_diagnostic(diagnostics, :accepted, reason)

      {:skip, reason} ->
        increment_diagnostic(diagnostics, :rejected, reason)
    end
  end

  def increment_diagnostic(diag, bucket, reason) when is_map(diag) do
    reason_key = to_string(reason)

    diag
    |> update_in([bucket, reason_key], fn
      nil -> 1
      existing -> existing + 1
    end)
    |> Map.update!(:total, &(&1 + 1))
  end
end
