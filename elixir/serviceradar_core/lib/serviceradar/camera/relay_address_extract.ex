defmodule ServiceRadar.Camera.RelayAddressExtract do
  @moduledoc """
  The relay address extract of the Stage 1 ingest rule (design D2 of the
  `resolve-camera-stream-sources-at-edge` change).

  Until Core resolves stream sources at the edge, a relay still opens from
  `camera_sources.source_url` and `camera_stream_profiles.source_url_override`.
  `PluginResultIngestor` reduces every plugin result on entry
  (`ServiceRadar.Camera.StreamAddressReduction`), so the reduced result no
  longer carries those addresses. Before reducing, it takes this extract from
  the unreduced result: per camera (`vendor`, `vendor_camera_id`) the value
  destined for `source_url`, and per profile of that camera (`profile_name`) the
  value destined for `source_url_override`, found with
  `ServiceRadar.Camera.InventoryIngestor`'s own descriptor normalization so that
  cameras and profiles match exactly as its upserts match them.

  The extract lives only for one ingest call. It is handed to
  `InventoryIngestor` alone, whose `put_relay_addresses/2` is the only setter of
  the two columns, and it is never persisted, logged or put in an event, error
  or command result. Its `Inspect` implementation shows the camera and profile
  keys, never the addresses.

  Stage 3 deletes this module.
  """

  alias ServiceRadar.Camera.InventoryIngestor

  @enforce_keys [:sources, :profiles]
  defstruct [:sources, :profiles]

  @type camera_key :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          sources: %{camera_key() => String.t()},
          profiles: %{{String.t(), String.t(), String.t()} => String.t()}
        }

  @doc "An extract that holds no address."
  @spec empty() :: t()
  def empty, do: %__MODULE__{sources: %{}, profiles: %{}}

  @doc """
  Takes the relay addresses from an unreduced plugin result. For a list of
  results it uses the entry `InventoryIngestor.ingest/3` would ingest.
  """
  @spec from_result(term()) :: t()
  def from_result(payload) when is_list(payload) do
    case Enum.find(payload, &InventoryIngestor.supports?(&1, %{})) do
      nil -> empty()
      entry -> from_result(entry)
    end
  end

  def from_result(payload) when is_map(payload) do
    payload
    |> InventoryIngestor.relay_address_entries()
    |> Enum.reduce(empty(), &put_entry/2)
  end

  def from_result(_payload), do: empty()

  @doc "The address destined for the camera's `source_url`, or nil."
  @spec source_url(t(), camera_key()) :: String.t() | nil
  def source_url(%__MODULE__{sources: sources}, camera_key), do: Map.get(sources, camera_key)

  @doc "The address destined for the profile's `source_url_override`, or nil."
  @spec profile_url(t(), camera_key(), String.t()) :: String.t() | nil
  def profile_url(%__MODULE__{profiles: profiles}, {vendor, vendor_camera_id}, profile_name),
    do: Map.get(profiles, {vendor, vendor_camera_id, profile_name})

  defp put_entry(%{camera: {vendor, vendor_camera_id} = camera} = entry, extract) do
    profiles =
      Enum.reduce(entry.profiles, extract.profiles, fn {profile_name, url}, acc ->
        put_present(acc, {vendor, vendor_camera_id, profile_name}, url)
      end)

    %{
      extract
      | sources: put_present(extract.sources, camera, entry.source_url),
        profiles: profiles
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{sources: sources, profiles: profiles}, opts) do
      concat([
        "#ServiceRadar.Camera.RelayAddressExtract<",
        to_doc(%{cameras: Map.keys(sources), profiles: Map.keys(profiles)}, opts),
        ">"
      ])
    end
  end
end
