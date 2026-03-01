defmodule ServiceRadarWebNG.Topology.GodViewSnapshot do
  @moduledoc """
  Contract guardrails for God-View topology snapshot payloads.

  This module validates the envelope metadata for streamed topology revisions.
  Payload transport/encoding can evolve (Arrow IPC, etc.) without changing the
  revision envelope consumed by the UI.
  """

  @schema_version 2
  @required_keys ~w(schema_version revision generated_at nodes edges causal_bitmaps bitmap_metadata)a
  @required_edge_keys ~w(
    source
    target
    flow_pps
    flow_bps
    flow_pps_ab
    flow_pps_ba
    flow_bps_ab
    flow_bps_ba
    capacity_bps
    telemetry_eligible
    protocol
    evidence_class
    confidence_tier
    local_if_index_ab
    local_if_name_ab
    local_if_index_ba
    local_if_name_ba
  )a

  @type snapshot :: %{
          required(:schema_version) => pos_integer(),
          required(:revision) => non_neg_integer(),
          required(:generated_at) => DateTime.t(),
          required(:nodes) => list(map()),
          required(:edges) => list(map()),
          required(:causal_bitmaps) => %{
            optional(:root_cause) => binary(),
            optional(:affected) => binary(),
            optional(:healthy) => binary(),
            optional(:unknown) => binary()
          },
          required(:bitmap_metadata) => %{
            optional(:root_cause) => %{
              optional(:bytes) => non_neg_integer(),
              optional(:count) => non_neg_integer()
            },
            optional(:affected) => %{
              optional(:bytes) => non_neg_integer(),
              optional(:count) => non_neg_integer()
            },
            optional(:healthy) => %{
              optional(:bytes) => non_neg_integer(),
              optional(:count) => non_neg_integer()
            },
            optional(:unknown) => %{
              optional(:bytes) => non_neg_integer(),
              optional(:count) => non_neg_integer()
            }
          },
          optional(:pipeline_stats) => map()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec required_keys() :: [atom()]
  def required_keys, do: @required_keys

  @spec required_edge_keys() :: [atom()]
  def required_edge_keys, do: @required_edge_keys

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{} = snapshot) do
    with :ok <- validate_required_keys(snapshot),
         :ok <- validate_schema_version(snapshot),
         :ok <- validate_revision(snapshot),
         :ok <- validate_generated_at(snapshot),
         :ok <- validate_nodes(snapshot),
         :ok <- validate_edges(snapshot),
         :ok <- validate_bitmaps(snapshot) do
      with :ok <- validate_bitmap_metadata(snapshot) do
        validate_pipeline_stats(snapshot)
      end
    end
  end

  def validate(_), do: {:error, :invalid_snapshot}

  @spec supported_schema?(integer()) :: boolean()
  def supported_schema?(version) when is_integer(version), do: version == @schema_version
  def supported_schema?(_), do: false

  defp validate_required_keys(snapshot) do
    missing = Enum.reject(@required_keys, &Map.has_key?(snapshot, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_keys, missing}}
    end
  end

  defp validate_schema_version(%{schema_version: version}) when is_integer(version) do
    if supported_schema?(version), do: :ok, else: {:error, {:unsupported_schema, version}}
  end

  defp validate_schema_version(_), do: {:error, :invalid_schema_version}

  defp validate_revision(%{revision: revision}) when is_integer(revision) and revision >= 0,
    do: :ok

  defp validate_revision(_), do: {:error, :invalid_revision}

  defp validate_generated_at(%{generated_at: %DateTime{}}), do: :ok

  defp validate_generated_at(%{generated_at: generated_at}) when is_binary(generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, _dt, _offset} -> :ok
      {:error, _reason} -> {:error, :invalid_generated_at}
    end
  end

  defp validate_generated_at(_), do: {:error, :invalid_generated_at}

  defp validate_nodes(%{nodes: nodes}) when is_list(nodes), do: :ok
  defp validate_nodes(_), do: {:error, :invalid_nodes}

  defp validate_edges(%{edges: edges}) when is_list(edges) do
    with :ok <- validate_edge_required_keys(edges) do
      validate_edge_values(edges)
    end
  end

  defp validate_edges(_), do: {:error, :invalid_edges}

  defp validate_bitmaps(%{causal_bitmaps: %{} = bitmaps}) do
    if Enum.all?(bitmaps, &valid_bitmap_entry?/1),
      do: :ok,
      else: {:error, :invalid_causal_bitmaps}
  end

  defp validate_bitmaps(_), do: {:error, :invalid_causal_bitmaps}

  defp validate_bitmap_metadata(%{bitmap_metadata: metadata}) when is_map(metadata) do
    if Enum.all?(metadata, &valid_bitmap_metadata_entry?/1),
      do: :ok,
      else: {:error, :invalid_bitmap_metadata}
  end

  defp validate_bitmap_metadata(_), do: {:error, :invalid_bitmap_metadata}

  defp validate_pipeline_stats(%{pipeline_stats: stats}) when is_map(stats), do: :ok
  defp validate_pipeline_stats(%{}), do: :ok
  defp validate_pipeline_stats(_), do: {:error, :invalid_pipeline_stats}

  defp valid_bitmap_entry?({key, value})
       when key in [:root_cause, :affected, :healthy, :unknown] and is_binary(value),
       do: true

  defp valid_bitmap_entry?(_), do: false

  defp valid_bitmap_metadata_entry?({key, %{bytes: bytes, count: count}})
       when key in [:root_cause, :affected, :healthy, :unknown] and is_integer(bytes) and
              bytes >= 0 and is_integer(count) and count >= 0,
       do: true

  defp valid_bitmap_metadata_entry?(_), do: false

  defp validate_edge_required_keys(edges) do
    case Enum.find_index(edges, &(missing_edge_keys(&1) != [])) do
      nil ->
        :ok

      idx ->
        missing = edges |> Enum.at(idx) |> missing_edge_keys()
        {:error, {:invalid_edge_schema, idx, {:missing_keys, missing}}}
    end
  end

  defp validate_edge_values(edges) do
    case Enum.find_index(edges, &(invalid_edge_value_reasons(&1) != [])) do
      nil ->
        :ok

      idx ->
        reasons = edges |> Enum.at(idx) |> invalid_edge_value_reasons()
        {:error, {:invalid_edge_schema, idx, {:invalid_values, reasons}}}
    end
  end

  defp missing_edge_keys(edge) when is_map(edge) do
    Enum.reject(@required_edge_keys, &edge_has_key?(edge, &1))
  end

  defp missing_edge_keys(_), do: @required_edge_keys

  defp invalid_edge_value_reasons(edge) when is_map(edge) do
    source = edge_fetch(edge, :source)
    target = edge_fetch(edge, :target)
    telemetry_eligible = edge_fetch(edge, :telemetry_eligible)
    flow_pps = edge_fetch(edge, :flow_pps)
    flow_bps = edge_fetch(edge, :flow_bps)
    flow_pps_ab = edge_fetch(edge, :flow_pps_ab)
    flow_pps_ba = edge_fetch(edge, :flow_pps_ba)
    flow_bps_ab = edge_fetch(edge, :flow_bps_ab)
    flow_bps_ba = edge_fetch(edge, :flow_bps_ba)
    capacity_bps = edge_fetch(edge, :capacity_bps)
    local_if_index_ab = edge_fetch(edge, :local_if_index_ab)
    local_if_index_ba = edge_fetch(edge, :local_if_index_ba)
    local_if_name_ab = edge_fetch(edge, :local_if_name_ab)
    local_if_name_ba = edge_fetch(edge, :local_if_name_ba)
    protocol = edge_fetch(edge, :protocol)
    evidence_class = edge_fetch(edge, :evidence_class)
    confidence_tier = edge_fetch(edge, :confidence_tier)

    []
    |> maybe_add_invalid(:source, not valid_non_empty_binary?(source))
    |> maybe_add_invalid(:target, not valid_non_empty_binary?(target))
    |> maybe_add_invalid(:source_target_equal, source == target)
    |> maybe_add_invalid(:telemetry_eligible, not is_boolean(telemetry_eligible))
    |> maybe_add_invalid(:flow_pps, not valid_non_negative_int?(flow_pps))
    |> maybe_add_invalid(:flow_bps, not valid_non_negative_int?(flow_bps))
    |> maybe_add_invalid(:flow_pps_ab, not valid_non_negative_int?(flow_pps_ab))
    |> maybe_add_invalid(:flow_pps_ba, not valid_non_negative_int?(flow_pps_ba))
    |> maybe_add_invalid(:flow_bps_ab, not valid_non_negative_int?(flow_bps_ab))
    |> maybe_add_invalid(:flow_bps_ba, not valid_non_negative_int?(flow_bps_ba))
    |> maybe_add_invalid(:capacity_bps, not valid_non_negative_int?(capacity_bps))
    |> maybe_add_invalid(:local_if_index_ab, not valid_if_index_value?(local_if_index_ab))
    |> maybe_add_invalid(:local_if_index_ba, not valid_if_index_value?(local_if_index_ba))
    |> maybe_add_invalid(:local_if_name_ab, not is_binary(local_if_name_ab))
    |> maybe_add_invalid(:local_if_name_ba, not is_binary(local_if_name_ba))
    |> maybe_add_invalid(:protocol, not is_binary(protocol))
    |> maybe_add_invalid(:evidence_class, not is_binary(evidence_class))
    |> maybe_add_invalid(:confidence_tier, not is_binary(confidence_tier))
  end

  defp invalid_edge_value_reasons(_), do: [:invalid_edge]

  defp maybe_add_invalid(reasons, _key, false), do: reasons
  defp maybe_add_invalid(reasons, key, true), do: reasons ++ [key]

  defp valid_non_negative_int?(value), do: is_integer(value) and value >= 0

  defp valid_if_index_value?(value), do: is_nil(value) or (is_integer(value) and value >= 0)

  defp valid_non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_non_empty_binary?(_), do: false

  defp edge_has_key?(edge, key) when is_map(edge) and is_atom(key) do
    Map.has_key?(edge, key) or Map.has_key?(edge, Atom.to_string(key))
  end

  defp edge_fetch(edge, key) when is_map(edge) and is_atom(key) do
    cond do
      Map.has_key?(edge, key) ->
        Map.get(edge, key)

      Map.has_key?(edge, Atom.to_string(key)) ->
        Map.get(edge, Atom.to_string(key))

      true ->
        nil
    end
  end
end
