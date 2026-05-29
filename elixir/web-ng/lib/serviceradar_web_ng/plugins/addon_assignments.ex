defmodule ServiceRadarWebNG.Plugins.AddonAssignments do
  @moduledoc """
  Context module for native add-on (feature set) assignments (issue 3425).

  Wraps the serviceradar_core ServiceRadar.Plugins.AddonAssignment Ash resource.
  The UI supplies only agent_uid, addon_package_id, params, and args — addon_id is
  denormalized server-side by the SetAssignmentAddonId change. No secret-ref or
  service-state handling is needed (those are Wasm-plugin specific).
  """

  alias ServiceRadar.Plugins.AddonAssignment

  require Ash.Query

  @default_limit 200
  @max_limit 500

  @spec list(map(), keyword()) :: [AddonAssignment.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> maybe_filter_agent_uid(filters)
    |> maybe_filter_package_id(filters)
    |> Ash.Query.limit(limit)
    |> Ash.Query.sort(inserted_at: :desc)
    |> read(scope)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, AddonAssignment.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, AddonAssignment.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    attrs = drop_nil_values(attrs)

    AddonAssignment
    |> Ash.Changeset.for_create(:create, attrs)
    |> create_with_scope(scope)
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec delete(String.t(), keyword()) :: {:ok, AddonAssignment.t()} | :ok | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, assignment} <- get(id, scope: scope) do
      assignment
      |> Ash.Changeset.for_destroy(:destroy)
      |> destroy_with_scope(scope)
      |> case do
        :ok -> {:ok, assignment}
        other -> other
      end
    end
  end

  def delete(_id, _opts), do: {:error, :invalid_attributes}

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one(id, nil) do
    AddonAssignment |> Ash.Query.for_read(:read) |> Ash.Query.filter(id == ^id) |> Ash.read_one()
  end

  defp read_one(id, scope) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp create_with_scope(changeset, nil), do: Ash.create(changeset)
  defp create_with_scope(changeset, scope), do: Ash.create(changeset, scope: scope)

  defp destroy_with_scope(changeset, nil), do: Ash.destroy(changeset)
  defp destroy_with_scope(changeset, scope), do: Ash.destroy(changeset, scope: scope)

  defp maybe_filter_agent_uid(query, filters) do
    agent_uid = Map.get(filters, :agent_uid) || Map.get(filters, "agent_uid")

    if is_binary(agent_uid) and agent_uid != "" do
      Ash.Query.filter(query, agent_uid == ^agent_uid)
    else
      query
    end
  end

  defp maybe_filter_package_id(query, filters) do
    package_id = Map.get(filters, :addon_package_id) || Map.get(filters, "addon_package_id")

    if is_binary(package_id) and package_id != "" do
      Ash.Query.filter(query, addon_package_id == ^package_id)
    else
      query
    end
  end

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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
