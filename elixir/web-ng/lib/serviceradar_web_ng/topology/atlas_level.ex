defmodule ServiceRadarWebNG.Topology.AtlasLevel do
  @moduledoc """
  Enriches an already-admitted semantic level and fingerprints its displayed data.

  Graph selection versions are internal inputs, not validators for enriched
  content. Inventory timestamps are deliberately absent from the fingerprint:
  the actual projected values determine freshness, including last-seen updates
  that do not advance the device modification timestamp.

  Camera source/profile details remain deferred until their reads are bounded.
  The JSON size guard bounds this internal read model; schema-3 delivery must
  independently measure the final Arrow bytes once its encoder is available.
  """

  alias ServiceRadarWebNG.Topology.GodViewStream

  @text_bytes 256
  @read_model_bytes 1_048_576

  @spec enrich(map(), %{String.t() => map()}) :: {:ok, map()} | {:error, atom()}
  def enrich(level, devices_by_id) do
    nodes = Enum.map(level.nodes, &enrich_node(&1, devices_by_id))

    content =
      level
      |> Map.drop([:canonical_revision, :revision, :structure_revision])
      |> Map.put(:nodes, nodes)
      |> Map.put(:deferred_details, ["camera"])
      |> Map.update!(:budgets, &Map.merge(&1, %{text_bytes: @text_bytes, read_model_bytes: @read_model_bytes}))

    structure = {level.structure_revision, Enum.map(nodes, &geometry_identity/1)}

    enriched =
      content
      |> Map.put(:revision, fingerprint(content))
      |> Map.put(:structure_revision, fingerprint(structure))
      |> Map.put(:canonical_revision, Map.get(level, :canonical_revision))

    case Jason.encode_to_iodata(enriched) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= @read_model_bytes,
          do: {:ok, enriched},
          else: {:error, :payload_too_large}

      {:error, _reason} ->
        {:error, :invalid_level_content}
    end
  end

  defp enrich_node(%{aggregate: true} = node, _devices) do
    Map.update!(node, :label, &identity_label(&1, node.id))
  end

  defp enrich_node(node, devices) do
    device = Map.get(devices, node.id)
    attributes = GodViewStream.device_node_attributes(device, node.id, nil, false)

    details =
      Map.new(attributes.details, fn
        {key, value} when key in [:id, :device_uid] -> {key, value}
        {key, value} -> {key, bounded_value(value)}
      end)

    node
    |> Map.merge(attributes)
    |> Map.put(:label, identity_label(attributes.label, node.id))
    |> Map.put(:kind, bounded_value(attributes.kind))
    |> Map.put(:details, details)
    |> Map.put(:inventory_present, not is_nil(device))
  end

  defp geometry_identity(node) do
    {Map.take(node, [:id, :kind, :type, :cluster_kind]),
     Map.take(Map.get(node, :details, %{}), [
       :type,
       :cluster_kind,
       :cluster_expanded,
       :cluster_anchor_id,
       :identity_source,
       :topology_plane,
       :topology_unplaced
     ])}
  end

  defp identity_label(label, id) do
    case bounded_value(label) do
      value when is_binary(value) and value != "" -> value
      _ -> id
    end
  end

  defp bounded_value(value) when is_binary(value) do
    prefix = binary_part(value, 0, min(byte_size(value), @text_bytes))

    case :unicode.characters_to_binary(prefix) do
      text when is_binary(text) -> String.trim(text)
      {_error_or_incomplete, text, _rest} -> String.trim(text)
    end
  end

  defp bounded_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp bounded_value(_value), do: nil

  defp fingerprint(term) do
    <<value::unsigned-size(52), _::bitstring>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

    value
  end
end
