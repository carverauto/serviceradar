defmodule ServiceRadar.Inventory.AdvisoryFeeds.Json do
  @moduledoc """
  JSON decode used by advisory-feed shard readers.

  Jason is enough here. Torque (sonic-rs / SIMD, hex.pm/torque) is ~2x faster
  on decode, but nist-nvd2's hour is the GIN-indexed `raw` upsert of ~360k
  CVE documents, not Jason. Adding Torque means a new Rustler NIF through
  mix + Bazel/RBE; do that only if a profile still shows decode on the clock.
  """

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary), do: Jason.decode(binary)

  @spec decode!(binary()) :: term()
  def decode!(binary) do
    case decode(binary) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise "failed to decode JSON: #{inspect(reason)}"
    end
  end
end
