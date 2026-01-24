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
    manifest = Ash.Changeset.get_attribute(changeset, :manifest) || %{}
    config_schema = Ash.Changeset.get_attribute(changeset, :config_schema)

    errors =
      case Manifest.from_map(manifest) do
        {:ok, _manifest} -> []
        {:error, errs} -> errs
      end

    errors =
      case Manifest.validate_config_schema(config_schema) do
        :ok -> errors
        {:error, errs} -> errors ++ errs
      end

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
end
