defmodule ServiceRadarWebNG.Plugins.AddonPackages do
  @moduledoc """
  Context module for native add-on (feature set) packages (issue 3425).

  Thin wrapper over the serviceradar_core ServiceRadar.Plugins.AddonPackage Ash
  resource, threading the authenticated scope into Ash for authorization. Add-ons
  have no Wasm blob / upload / import flow, so this is much smaller than the
  Wasm Packages context.
  """

  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [AddonPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> maybe_filter_status(filters)
    |> Ash.Query.limit(limit)
    |> Ash.Query.sort(inserted_at: :desc)
    |> read(scope)
  end

  @spec list_approved(keyword()) :: [AddonPackage.t()]
  def list_approved(opts \\ []), do: list(%{status: :approved}, opts)

  @spec get(String.t(), keyword()) ::
          {:ok, AddonPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one(id, nil) do
    AddonPackage |> Ash.Query.for_read(:read) |> Ash.Query.filter(id == ^id) |> Ash.read_one()
  end

  defp read_one(id, scope) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp maybe_filter_status(query, filters) do
    case status_atom(Map.get(filters, :status) || Map.get(filters, "status")) do
      nil -> query
      status -> Ash.Query.filter(query, status == ^status)
    end
  end

  defp status_atom(status) when is_atom(status) and not is_nil(status), do: status

  defp status_atom(status) when is_binary(status) and status != "" do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp status_atom(_status), do: nil

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit
end
