defmodule ServiceRadar.Identity.RoleMappingSupport do
  @moduledoc false

  @allowed_roles ServiceRadar.Identity.Constants.allowed_roles()
  @allowed_role_strings Map.new(@allowed_roles, &{Atom.to_string(&1), &1})

  def allowed_roles, do: @allowed_roles

  def normalize_role(nil), do: nil
  def normalize_role(role) when role in @allowed_roles, do: role
  def normalize_role(role) when is_binary(role), do: Map.get(@allowed_role_strings, role)
  def normalize_role(_role), do: nil

  def get_key(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || get_atom_key(map, key)
  end

  def get_key(map, key) when is_map(map), do: Map.get(map, key)

  defp get_atom_key(map, key) do
    atom_key = String.to_existing_atom(key)
    Map.get(map, atom_key)
  rescue
    ArgumentError -> nil
  end
end
