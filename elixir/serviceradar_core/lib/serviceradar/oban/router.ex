defmodule ServiceRadar.Oban.Router do
  @moduledoc """
  Routes Oban inserts to the platform or tenant-specific Oban instance.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Oban.TenantOban

  def insert(changeset, opts \\ []) do
    {name, opts} = resolve_insert_opts(changeset, opts)
    Oban.insert(name, changeset, opts)
  end

  def insert!(changeset, opts \\ []) do
    {name, opts} = resolve_insert_opts(changeset, opts)
    Oban.insert!(name, changeset, opts)
  end

  def insert_all(changesets, opts \\ []) do
    changesets = Enum.to_list(changesets)

    case changesets do
      [] ->
        []

      [first | _] ->
        case tenant_schema_from_changeset(first) do
          nil ->
            Oban.insert_all(changesets, opts)

          schema ->
            case TenantOban.ensure_schema(schema) do
              {:ok, name} -> Oban.insert_all(name, changesets, opts)
              {:error, _} -> Oban.insert_all(changesets, opts)
            end
        end
    end
  end

  defp resolve_insert_opts(changeset, opts) do
    case tenant_schema_from_changeset(changeset) do
      nil ->
        {Oban, opts}

      schema ->
        case TenantOban.ensure_schema(schema) do
          {:ok, name} -> {name, opts}
          {:error, _} -> {Oban, opts}
        end
    end
  end

  defp tenant_schema_from_changeset(changeset) do
    args = Ecto.Changeset.get_field(changeset, :args) || %{}

    cond do
      schema = Map.get(args, "tenant_schema") ->
        schema

      schema = Map.get(args, :tenant_schema) ->
        schema

      tenant = Map.get(args, "tenant") ->
        TenantSchemas.schema_for_tenant(tenant)

      tenant = Map.get(args, :tenant) ->
        TenantSchemas.schema_for_tenant(tenant)

      tenant_id = Map.get(args, "tenant_id") ->
        TenantSchemas.schema_for_id(tenant_id)

      tenant_id = Map.get(args, :tenant_id) ->
        TenantSchemas.schema_for_id(tenant_id)

      true ->
        nil
    end
  end
end
