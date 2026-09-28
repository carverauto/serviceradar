defmodule ServiceRadar.Inventory.Validations.EphemeralExpiryExclusionQuery do
  @moduledoc """
  The ephemeral-expiry exclusion query, when set, must be valid SRQL targeting devices. An
  empty value means "exclude nothing".
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @field :ephemeral_expiry_exclusion_query

  @impl true
  def validate(changeset, _opts, _context) do
    changeset |> Ash.Changeset.get_attribute(@field) |> validate_value()
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, @field) do
      {:ok, value} -> validate_value(value)
      :error -> :ok
    end
  end

  @doc false
  def validate_value(nil), do: :ok

  def validate_value(query) when is_binary(query) do
    case String.trim(query) do
      "" -> :ok
      query -> query |> SRQLQuery.ensure_target(:devices) |> validate_device_query()
    end
  end

  def validate_value(_query), do: {:error, field: @field, message: "must be an SRQL query"}

  defp validate_device_query(query) do
    if SRQLAst.entity(query) == "devices" do
      case SRQLAst.validate(query) do
        :ok -> :ok
        {:error, reason} -> {:error, field: @field, message: "Invalid SRQL query: #{reason}"}
      end
    else
      {:error, field: @field, message: "must target devices"}
    end
  end
end
