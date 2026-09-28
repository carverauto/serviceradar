defmodule ServiceRadar.Credentials.Validations.TargetQuery do
  @moduledoc """
  Validates network credential rule target queries against device inventory.

  SRQL is parsed in Elixir, so the check cannot be pushed into the database.
  An atomic update validates the literal query it is about to write; one that
  leaves `target_query` alone keeps a value that passed this validation when
  it was stored.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Credentials.Validations.ProposedValue
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @impl true
  def atomic(changeset, _opts, _context) do
    case ProposedValue.fetch(changeset, :target_query) do
      :unchanged -> :ok
      {:changed, query} -> validate_value(query)
      {:not_atomic, _reason} = not_atomic -> not_atomic
    end
  end

  @impl true
  def validate(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:target_query)
    |> validate_value()
  end

  defp validate_value(query) when is_binary(query) and query != "", do: validate_query(query)
  defp validate_value(_query), do: {:error, field: :target_query, message: "is required"}

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
