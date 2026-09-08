defmodule ServiceRadar.Identity.RoleMappingSupport do
  @moduledoc false

  @allowed_roles ServiceRadar.Identity.Constants.allowed_roles()
  @allowed_role_strings Map.new(@allowed_roles, &{Atom.to_string(&1), &1})

  def allowed_roles, do: @allowed_roles

  @doc """
  Rank of a role, higher meaning more privilege.

  `Constants.allowed_roles/0` is declared in ascending privilege order, so the
  index is the rank. Resolution needs an explicit ordering because when several
  mappings match, the highest matched role wins -- comparing role atoms would
  order them alphabetically, which puts :admin below :helpdesk and :operator.
  """
  def role_rank(role) do
    case Enum.find_index(@allowed_roles, &(&1 == role)) do
      nil -> -1
      index -> index
    end
  end

  @doc "The highest-privilege role in `roles`, or nil when empty."
  def highest_role([]), do: nil

  def highest_role(roles) when is_list(roles) do
    roles
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&role_rank/1, fn -> nil end)
  end

  def highest_role(_roles), do: nil

  @doc "Trims a string to nil when blank, passing other values through unchanged."
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_value), do: nil

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
