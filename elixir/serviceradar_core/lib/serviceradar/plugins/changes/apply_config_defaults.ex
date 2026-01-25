defmodule ServiceRadar.Plugins.Changes.ApplyConfigDefaults do
  @moduledoc """
  Applies config schema defaults and type normalization to assignment params.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.ConfigSchema

  @impl true
  def change(changeset, _opts, _context) do
    params =
      Ash.Changeset.get_attribute(changeset, :params) ||
        Map.get(changeset.data, :params) || %{}

    schema = Map.get(changeset.context, :config_schema) || %{}

    case schema do
      %{} = schema when map_size(schema) > 0 ->
        normalized = ConfigSchema.normalize_params(schema, params)
        Ash.Changeset.change_attribute(changeset, :params, normalized)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
