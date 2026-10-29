defmodule ServiceRadar.Inventory.Identity.TlsCertificateFingerprint do
  @moduledoc """
  A host's TLS certificate fingerprint as a strong identifier
  (`tls_certificate_fingerprint`).

  The one certificate admitted is a Proxmox VE node's own `pve-ssl.pem`. Proxmox
  generates it per node, with the node's own key, signed by the cluster CA, so two
  sources see the same node-unique value without sharing anything else:

    * the Proxmox inventory reads it from `GET /nodes/{node}/certificates/info`;
    * the agent on that node reads it from the certificate its local pveproxy
      presents on port 8006, keeping it only when the subject carries the node
      certificate's `PVE Cluster Node` unit.

  That is what links a node record that carries no MAC (the PVE API returns no
  hardware address) to the agent's device for the same host, without trusting a
  hostname or an address. A custom or ACME `pveproxy-ssl.pem` can be one wildcard
  certificate shared by many nodes or clusters, so neither producer emits it and
  it never identifies a host. Two same-named nodes have two `pve-ssl.pem` keys,
  so they never share a value.

  Values are `pve:sha256:<64 lowercase hex>`. Only first-party claimers carry one
  into identity: the agent describing its own host and the Proxmox inventory
  describing its own node. An observer (mapper, sweep, census) never does, even
  if a value reached its metadata.
  """

  @metadata_key "tls_certificate_fingerprint"
  @metadata_atom :tls_certificate_fingerprint
  @prefix "pve:sha256:"
  @claimer_sources ["agent_gateway_sync", "proxmox", "hypervisor_enrichment"]

  @doc "The device-update metadata key a fingerprint travels under."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  Normalizes a fingerprint to `pve:sha256:<64 lowercase hex>`, or nil.

  Accepts the scoped form, with or without the API's colon-separated
  uppercase hex.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(@prefix <> hex), do: with_prefix(normalize_sha256(hex))
  def normalize(_value), do: nil

  @doc "Scopes a bare SHA-256 hex digest, as the agent reports it, to `pve:sha256:`."
  @spec from_sha256(term()) :: String.t() | nil
  def from_sha256(value), do: value |> normalize_sha256() |> with_prefix()

  @doc """
  The fingerprint a device update claims, when its source may claim one.
  """
  @spec from_update(map()) :: String.t() | nil
  def from_update(update) when is_map(update) do
    if claimer?(update) do
      update
      |> field(:metadata)
      |> metadata_value()
      |> normalize()
    end
  end

  def from_update(_update), do: nil

  defp claimer?(update) do
    source = update |> field(:source) |> to_string() |> String.downcase()
    source in @claimer_sources
  end

  defp metadata_value(metadata) when is_map(metadata) do
    Map.get(metadata, @metadata_key) || Map.get(metadata, @metadata_atom)
  end

  defp metadata_value(_metadata), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_sha256(value) when is_binary(value) do
    hex = value |> String.trim() |> String.replace(":", "") |> String.downcase()

    if String.length(hex) == 64 and String.match?(hex, ~r/\A[0-9a-f]+\z/), do: hex
  end

  defp normalize_sha256(_value), do: nil

  defp with_prefix(nil), do: nil
  defp with_prefix(hex), do: @prefix <> hex
end
