defmodule ServiceRadarWebNG.Topology.GodViewSnapshot do
  @moduledoc """
  Contract guardrails for God-View topology snapshot payloads.

  This module validates the envelope metadata for streamed topology revisions.
  Payload transport/encoding can evolve (Arrow IPC, etc.) without changing the
  revision envelope consumed by the UI.
  """

  @schema_version 1
  @required_keys ~w(schema_version revision generated_at nodes edges causal_bitmaps bitmap_metadata)a

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
          }
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{} = snapshot) do
    with :ok <- validate_required_keys(snapshot),
         :ok <- validate_schema_version(snapshot),
         :ok <- validate_revision(snapshot),
         :ok <- validate_generated_at(snapshot),
         :ok <- validate_nodes(snapshot),
         :ok <- validate_edges(snapshot),
         :ok <- validate_bitmaps(snapshot),
         :ok <- validate_bitmap_metadata(snapshot) do
      :ok
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

  defp validate_edges(%{edges: edges}) when is_list(edges), do: :ok
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

  defp valid_bitmap_entry?({key, value})
       when key in [:root_cause, :affected, :healthy, :unknown] and is_binary(value),
       do: true

  defp valid_bitmap_entry?(_), do: false

  defp valid_bitmap_metadata_entry?({key, %{bytes: bytes, count: count}})
       when key in [:root_cause, :affected, :healthy, :unknown] and is_integer(bytes) and
              bytes >= 0 and is_integer(count) and count >= 0,
       do: true

  defp valid_bitmap_metadata_entry?(_), do: false
end
