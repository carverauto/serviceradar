defmodule ServiceRadarWebNG.TenantUsage do
  @moduledoc """
  Canonical runtime-local usage facts for plan visibility and advisory hooks.
  """

  import Ecto.Query

  alias ServiceRadarWebNG.Repo

  @collector_usage_types ["flowgger", "trapd", "netflow", "sflow", "otel", "falcosidekick"]

  @spec collector_usage_types() :: [String.t()]
  def collector_usage_types, do: @collector_usage_types

  @spec managed_device_count() :: non_neg_integer()
  def managed_device_count do
    from(d in "ocsf_devices",
      where: is_nil(field(d, :deleted_at)),
      select: count()
    )
    |> Repo.one()
    |> normalize_count()
  rescue
    _ -> 0
  end

  @spec collector_counts_by_type() :: %{optional(String.t()) => non_neg_integer()}
  def collector_counts_by_type do
    from(p in "collector_packages",
      where: field(p, :status) not in ["revoked", "failed"],
      group_by: field(p, :collector_type),
      select: {field(p, :collector_type), count()}
    )
    |> Repo.all()
    |> Map.new(fn {collector_type, count} ->
      {normalize_collector_type(collector_type), normalize_count(count)}
    end)
  rescue
    _ -> %{}
  end

  defp normalize_collector_type(collector_type) when is_atom(collector_type), do: Atom.to_string(collector_type)

  defp normalize_collector_type(collector_type) when is_binary(collector_type), do: collector_type

  defp normalize_collector_type(_), do: "unknown"

  defp normalize_count(count) when is_integer(count), do: max(count, 0)
  defp normalize_count(_), do: 0
end
