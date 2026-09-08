defmodule ServiceRadar.CompositeChecks.Validations.ScopeQuery do
  @moduledoc """
  A composite check scope must be a valid SRQL query targeting devices.

  Mirrors `ServiceRadar.Inventory.Validations.AvailabilitySourceProfileTargetQuery`.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  # Delegate rather than returning a bare `:ok`: a validation whose `atomic/3`
  # returns `:ok` is treated as having nothing to check and is skipped entirely
  # when the action runs atomically, which would let an invalid scope through on
  # update.
  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :scope_query) do
      query when is_binary(query) and query != "" ->
        query
        |> SRQLQuery.ensure_target(:devices)
        |> validate_device_query()

      _ ->
        {:error, field: :scope_query, message: "is required"}
    end
  end

  defp validate_device_query(query) do
    if SRQLAst.entity(query) == "devices" do
      case SRQLAst.validate(query) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, field: :scope_query, message: "Invalid SRQL query: #{reason}"}
      end
    else
      {:error, field: :scope_query, message: "must target devices"}
    end
  end
end
