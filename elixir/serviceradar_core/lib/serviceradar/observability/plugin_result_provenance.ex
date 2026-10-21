defmodule ServiceRadar.Observability.PluginResultProvenance do
  @moduledoc """
  Host-stamped provenance of a Wasm plugin result: the assignment, plugin
  package and Wasm module that produced it.

  The agent host fills `monitoring.PluginResultProvenance` on the
  `GatewayServiceStatus` from its own assignment record and from the SHA-256 of
  the module bytes it loaded for the run. The plugin payload never contributes,
  so a plugin cannot claim to be another package. The gateway forwards it as
  `status.plugin_provenance`.

  `ServiceRadar.Observability.PluginResultIngestor` stores it in the `details`
  JSON of the plugin's service status:

    * the reported row (`service_status`, and `service_state` when no
      downstream handler runs) keeps it under
      `_serviceradar_plugin_result.provenance`, inside the server-authored
      marker that the ingestor strips from plugin payloads;
    * downstream-ingest success and failure rows keep it under
      `downstream_ingest.provenance`, a key the ingestor also reserves.

  A rollout health gate reads it with `from_details/1` on either table to
  confirm that a fresh result came from the candidate `plugin_package_id` and
  `content_hash` on that agent. Results from agents that predate provenance
  carry none; `from_details/1` returns `nil` for them, and a gate must treat that
  as "not proven", never as a match.

  Fields, all optional strings: `assignment_id`, `plugin_id`,
  `plugin_package_id`, `plugin_version` and `content_hash` (lowercase hex
  SHA-256, absent when the run loaded no module). Invalid values are dropped.
  """

  @marker_key "_serviceradar_plugin_result"
  @text_fields [:assignment_id, :plugin_id, :plugin_package_id, :plugin_version]
  @max_text_bytes 255
  @content_hash_pattern ~r/\A[0-9a-f]{64}\z/

  @type t :: %{optional(String.t()) => String.t()}

  @doc """
  Returns the validated provenance the gateway forwarded on `status`, or `nil`
  when the agent sent none.
  """
  @spec from_status(map()) :: t() | nil
  def from_status(status) when is_map(status),
    do: status |> fetch(:plugin_provenance) |> normalize()

  def from_status(_status), do: nil

  @doc """
  Reads the provenance stored in a plugin service status or state `details`
  value (a JSON string or decoded map). Returns `nil` when none was recorded.
  """
  @spec from_details(String.t() | map() | nil) :: t() | nil
  def from_details(details) do
    case decode(details) do
      %{@marker_key => marker} when is_map(marker) ->
        normalize(Map.get(marker, "provenance"))

      %{"downstream_ingest" => ingest} when is_map(ingest) ->
        normalize(Map.get(ingest, "provenance"))

      _ ->
        nil
    end
  end

  @doc false
  @spec put(map(), t() | nil) :: map()
  def put(map, nil), do: map
  def put(map, provenance) when is_map(provenance), do: Map.put(map, "provenance", provenance)

  defp normalize(provenance) when is_map(provenance) do
    normalized =
      @text_fields
      |> Enum.reduce(%{}, fn field, acc ->
        put_valid(acc, field, provenance |> fetch(field) |> valid_text())
      end)
      |> put_valid(:content_hash, provenance |> fetch(:content_hash) |> valid_hash())

    if map_size(normalized) == 0, do: nil, else: normalized
  end

  defp normalize(_provenance), do: nil

  defp put_valid(acc, _field, nil), do: acc
  defp put_valid(acc, field, value), do: Map.put(acc, Atom.to_string(field), value)

  defp valid_text(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and byte_size(trimmed) <= @max_text_bytes and String.printable?(trimmed) and
         not String.contains?(trimmed, ["\n", "\r", "\t"]) do
      trimmed
    end
  end

  defp valid_text(_value), do: nil

  defp valid_hash(value) when is_binary(value) do
    if Regex.match?(@content_hash_pattern, value), do: value
  end

  defp valid_hash(_value), do: nil

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil

  defp decode(details) when is_map(details), do: details

  defp decode(details) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode(_details), do: %{}
end
