defmodule ServiceRadar.Plugins.Validations.DisplayContracts do
  @moduledoc """
  Validates the `display_contracts` map a package ships.

  The importers already refuse a bundle whose contracts do not validate, but the
  importer is not the only writer: the admin API and the packages LiveView both
  create and update package rows. This validation is what makes the rule a
  property of the RESOURCE rather than of one code path, so a contract can never
  reach the runtime resolver without having passed
  `ServiceRadar.Plugins.DisplayContract.validate/1`.

  It also enforces the storage key, because the runtime resolver looks contracts
  up by `"<id>@<version>"` and a row whose key disagreed with its document would
  be unreachable - present in the database, invisible in the UI, and impossible
  to diagnose from either end.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Plugins.DisplayContract

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    contracts =
      Ash.Changeset.get_attribute(changeset, :display_contracts) ||
        Map.get(changeset.data, :display_contracts) || %{}

    case errors(contracts) do
      [] -> :ok
      errors -> {:error, field: :display_contracts, message: Enum.join(errors, "; ")}
    end
  end

  defp errors(contracts) when is_map(contracts) do
    Enum.flat_map(contracts, fn {key, document} ->
      key = to_string(key)

      case DisplayContract.validate(document) do
        {:ok, contract} ->
          expected = DisplayContract.key(contract)

          if expected == key do
            []
          else
            ["display_contracts.#{key} must be keyed as #{expected}"]
          end

        {:error, contract_errors} ->
          Enum.map(contract_errors, &"display_contracts.#{key}: #{&1}")
      end
    end)
  end

  defp errors(_contracts), do: ["display_contracts must be a map"]
end
