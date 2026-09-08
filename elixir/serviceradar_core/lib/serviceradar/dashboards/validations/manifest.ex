defmodule ServiceRadar.Dashboards.Validations.Manifest do
  @moduledoc """
  Validates dashboard package manifests on Ash resources.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Dashboards.Manifest

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    manifest =
      Ash.Changeset.get_attribute(changeset, :manifest) ||
        Map.get(changeset.data, :manifest) || %{}

    case Manifest.from_map(manifest) do
      {:ok, _manifest} ->
        :ok

      {:error, errors} ->
        message =
          errors
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("; ")

        {:error, field: :manifest, message: message}
    end
  end
end
