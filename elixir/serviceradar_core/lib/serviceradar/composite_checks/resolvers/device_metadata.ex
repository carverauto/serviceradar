defmodule ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata do
  @moduledoc """
  Resolves a `:device_metadata` input from a device's metadata map.

  Freshness comes from the provenance side-channel that the device fact write
  API maintains at `metadata["__fact_provenance"][path]`.

  `max_age_seconds` is optional, and that is deliberate. Without it the input
  resolves on the stored value alone and requires no provenance, so a metadata
  key written by a path that records none stays usable — otherwise every key
  predating the provenance side-channel would resolve `:unknown` forever. With
  it, absent provenance is indistinguishable from an arbitrarily old write and
  resolves `:unknown`.

  Pure: the caller passes the metadata map in.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput

  @provenance_key "__fact_provenance"

  @type value :: boolean() | :unknown
  @type resolution :: %{
          value: value(),
          observed_at: DateTime.t() | nil,
          stale: boolean(),
          reason: nil | :absent | :stale | :type_mismatch | :no_provenance
        }

  @spec resolve(CompositeCheckInput.t(), map() | nil, DateTime.t()) :: resolution()
  def resolve(input, metadata, now)

  def resolve(%CompositeCheckInput{} = input, nil, now), do: resolve(input, %{}, now)

  def resolve(%CompositeCheckInput{config: config}, metadata, now) when is_map(metadata) do
    path = Map.get(config, "path")
    max_age = Map.get(config, "max_age_seconds")

    case Map.fetch(metadata, path) do
      :error ->
        unknown(:absent, nil)

      {:ok, raw} ->
        case cast(raw, Map.get(config, "value_type")) do
          {:ok, value} -> apply_freshness(value, provenance_at(metadata, path), max_age, now)
          :error -> unknown(:type_mismatch, nil)
        end
    end
  end

  defp cast(value, "boolean") when is_boolean(value), do: {:ok, value}
  defp cast(_value, "boolean"), do: :error
  defp cast(_value, _type), do: :error

  defp apply_freshness(value, _observed_at, nil, _now) do
    %{value: value, observed_at: nil, stale: false, reason: nil}
  end

  defp apply_freshness(_value, nil, _max_age, _now), do: unknown(:no_provenance, nil)

  defp apply_freshness(value, observed_at, max_age, now) do
    if DateTime.diff(now, observed_at, :second) > max_age do
      %{value: :unknown, observed_at: observed_at, stale: true, reason: :stale}
    else
      %{value: value, observed_at: observed_at, stale: false, reason: nil}
    end
  end

  defp provenance_at(metadata, path) do
    with %{} = provenance <- Map.get(metadata, @provenance_key),
         %{} = entry <- Map.get(provenance, path),
         updated_at when is_binary(updated_at) <- Map.get(entry, "updated_at"),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(updated_at) do
      parsed
    else
      _ -> nil
    end
  end

  defp unknown(reason, observed_at) do
    %{value: :unknown, observed_at: observed_at, stale: reason == :stale, reason: reason}
  end

  @doc """
  The metadata key under which per-fact provenance is stored.

  The fact write API and this resolver must agree on it. A mismatch fails
  silently: every fact would resolve `:unknown` forever with no error anywhere.
  """
  def provenance_key, do: @provenance_key
end
