defmodule ServiceRadar.Inventory.Validations.AvailabilitySourceProfileTargetQuery do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :srql_query) do
      query when is_binary(query) and query != "" ->
        query
        |> SRQLQuery.ensure_target(:devices)
        |> validate_device_query()

      _ ->
        {:error, field: :srql_query, message: "is required"}
    end
  end

  defp validate_device_query(query) do
    if SRQLAst.entity(query) == "devices" do
      case SRQLAst.validate(query) do
        :ok -> :ok
        {:error, reason} -> {:error, field: :srql_query, message: "Invalid SRQL query: #{reason}"}
      end
    else
      {:error, field: :srql_query, message: "must target devices"}
    end
  end
end
