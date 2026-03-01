# Delegate to ServiceRadar.Repo from serviceradar_core
# This module exists for backwards compatibility
defmodule ServiceRadarWebNG.Repo do
  @moduledoc """
  This module delegates to ServiceRadar.Repo from serviceradar_core.
  It exists for backwards compatibility with existing code.
  """

  # Re-export ServiceRadar.Repo functionality
  defdelegate all(queryable, opts \\ []), to: ServiceRadar.Repo
  defdelegate get(queryable, id, opts \\ []), to: ServiceRadar.Repo
  defdelegate get!(queryable, id, opts \\ []), to: ServiceRadar.Repo
  defdelegate get_by(queryable, clauses, opts \\ []), to: ServiceRadar.Repo
  defdelegate get_by!(queryable, clauses, opts \\ []), to: ServiceRadar.Repo
  defdelegate one(queryable, opts \\ []), to: ServiceRadar.Repo
  defdelegate one!(queryable, opts \\ []), to: ServiceRadar.Repo
  defdelegate insert(struct_or_changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate insert!(struct_or_changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate update(changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate update!(changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate delete(struct_or_changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate delete!(struct_or_changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate transaction(fun_or_multi, opts \\ []), to: ServiceRadar.Repo
  defdelegate query(sql, params \\ [], opts \\ []), to: ServiceRadar.Repo
  defdelegate query!(sql, params \\ [], opts \\ []), to: ServiceRadar.Repo
  defdelegate aggregate(queryable, aggregate, field, opts \\ []), to: ServiceRadar.Repo
  defdelegate exists?(queryable, opts \\ []), to: ServiceRadar.Repo
  defdelegate preload(struct_or_structs_or_nil, preloads, opts \\ []), to: ServiceRadar.Repo
  defdelegate checkout(fun, opts \\ []), to: ServiceRadar.Repo

  # Additional Ecto.Repo functions needed by existing code
  defdelegate update_all(queryable, updates, opts \\ []), to: ServiceRadar.Repo
  defdelegate delete_all(queryable, opts \\ []), to: ServiceRadar.Repo
  defdelegate rollback(value), to: ServiceRadar.Repo
  defdelegate insert_all(schema_or_source, entries, opts \\ []), to: ServiceRadar.Repo
  defdelegate insert_or_update(changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate insert_or_update!(changeset, opts \\ []), to: ServiceRadar.Repo
  defdelegate reload(struct_or_structs, opts \\ []), to: ServiceRadar.Repo
  defdelegate reload!(struct_or_structs, opts \\ []), to: ServiceRadar.Repo
  defdelegate stream(queryable, opts \\ []), to: ServiceRadar.Repo

  # Custom helper functions - delegate to ServiceRadar.Repo
  # Note: transact is defined by Ecto.Repo and passes through results directly
  defdelegate transact(fun, opts \\ []), to: ServiceRadar.Repo
  defdelegate all_by(queryable, clauses, opts \\ []), to: ServiceRadar.Repo

  # get_dynamic_repo is required by Ecto.Adapters.SQL.Sandbox
  defdelegate get_dynamic_repo(), to: ServiceRadar.Repo
end
