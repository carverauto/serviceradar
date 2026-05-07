defmodule ServiceRadar.Credentials.Validations.TargetQuery do
  @moduledoc """
  Validates network credential rule target queries against device inventory.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :target_query) do
      query when is_binary(query) and query != "" ->
        validate_query(query)

      _ ->
        {:error, field: :target_query, message: "is required"}
    end
  end

  defp validate_query(query) do
    query
    |> SRQLQuery.ensure_target(:devices)
    |> SRQLAst.validate()
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, field: :target_query, message: "Invalid SRQL query: #{reason}"}
    end
  end
end
