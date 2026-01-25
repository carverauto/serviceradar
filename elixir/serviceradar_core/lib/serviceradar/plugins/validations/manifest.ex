defmodule ServiceRadar.Plugins.Validations.Manifest do
  @moduledoc """
  Validates plugin manifest and optional config schema.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Plugins.Manifest

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    manifest =
      Ash.Changeset.get_attribute(changeset, :manifest) ||
        Map.get(changeset.data, :manifest) || %{}

    config_schema =
      Ash.Changeset.get_attribute(changeset, :config_schema) ||
        Map.get(changeset.data, :config_schema)

    display_contract =
      Ash.Changeset.get_attribute(changeset, :display_contract) ||
        Map.get(changeset.data, :display_contract)

    errors =
      manifest_errors(manifest) ++
        config_schema_errors(config_schema) ++
        display_contract_errors(display_contract)

    case errors do
      [] ->
        :ok

      [first | rest] ->
        message =
          [first | rest]
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("; ")

        {:error, field: :manifest, message: message}
    end
  end

  defp manifest_errors(manifest) do
    case Manifest.from_map(manifest) do
      {:ok, _manifest} -> []
      {:error, errs} -> errs
    end
  end

  defp config_schema_errors(config_schema) do
    case Manifest.validate_config_schema(config_schema) do
      :ok -> []
      {:error, errs} -> errs
    end
  end

  defp display_contract_errors(display_contract) do
    case Manifest.validate_display_contract(display_contract) do
      :ok -> []
      {:error, errs} -> errs
    end
  end
end
