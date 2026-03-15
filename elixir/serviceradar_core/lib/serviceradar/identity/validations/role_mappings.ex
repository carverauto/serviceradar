defmodule ServiceRadar.Identity.Validations.RoleMappings do
  @moduledoc """
  Validates authorization role mappings.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Identity.RoleMappingSupport

  @allowed_sources ["groups", "email_domain", "email", "claim"]
  @allowed_keys ["source", "value", "role", "claim"]

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    mappings =
      Ash.Changeset.get_attribute(changeset, :role_mappings) ||
        Map.get(changeset.data, :role_mappings) || []

    case normalize_mappings(mappings) do
      {:ok, normalized} ->
        validate_mappings(normalized)

      {:error, message} ->
        {:error, field: :role_mappings, message: message}
    end
  end

  defp normalize_mappings(mappings) when is_list(mappings) do
    if Enum.all?(mappings, &is_map/1) do
      {:ok, mappings}
    else
      {:error, "role_mappings must be a list of objects"}
    end
  end

  defp normalize_mappings(_), do: {:error, "role_mappings must be a list of objects"}

  defp validate_mappings(mappings) do
    errors =
      mappings
      |> Enum.with_index()
      |> Enum.reduce([], fn {mapping, idx}, acc ->
        case validate_mapping(mapping) do
          :ok -> acc
          {:error, message} -> ["mapping #{idx}: #{message}" | acc]
        end
      end)

    if errors == [] do
      :ok
    else
      {:error, field: :role_mappings, message: Enum.join(Enum.reverse(errors), "; ")}
    end
  end

  defp validate_mapping(mapping) do
    source = RoleMappingSupport.get_key(mapping, "source")
    value = RoleMappingSupport.get_key(mapping, "value")
    role = RoleMappingSupport.get_key(mapping, "role")
    claim = RoleMappingSupport.get_key(mapping, "claim")

    with :ok <- validate_keys(mapping),
         :ok <- validate_source(source),
         :ok <- validate_value(value),
         :ok <- validate_role(role),
         :ok <- validate_claim(source, claim),
         :ok <- validate_value_format(source, value) do
      validate_claim_format(source, claim)
    end
  end

  defp validate_source(source) when is_binary(source) do
    if source in @allowed_sources do
      :ok
    else
      {:error, "source must be one of: #{Enum.join(@allowed_sources, ", ")}"}
    end
  end

  defp validate_source(_), do: {:error, "source is required"}

  defp validate_value(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "value is required"}
    else
      :ok
    end
  end

  defp validate_value(_), do: {:error, "value is required"}

  defp validate_role(role) when is_binary(role) do
    role_atom = RoleMappingSupport.normalize_role(role)
    validate_role(role_atom)
  end

  defp validate_role(role) do
    if role in RoleMappingSupport.allowed_roles() do
      :ok
    else
      {:error, "role must be one of: viewer, helpdesk, operator, admin"}
    end
  end

  defp validate_claim("claim", claim) do
    if is_binary(claim) and String.trim(claim) != "" do
      :ok
    else
      {:error, "claim is required for source 'claim'"}
    end
  end

  defp validate_claim(_, _), do: :ok

  defp validate_keys(mapping) when is_map(mapping) do
    keys =
      mapping
      |> Map.keys()
      |> Enum.map(fn key ->
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> to_string(other)
        end
      end)

    case Enum.reject(keys, &(&1 in @allowed_keys)) do
      [] -> :ok
      extras -> {:error, "unexpected keys: #{Enum.join(Enum.sort(extras), ", ")}"}
    end
  end

  defp validate_keys(_), do: {:error, "role_mappings must be a list of objects"}

  defp validate_value_format("email_domain", value) when is_binary(value) do
    if String.contains?(value, "@") do
      {:error, "value must be a domain (no @) for source 'email_domain'"}
    else
      :ok
    end
  end

  defp validate_value_format("email", value) when is_binary(value) do
    if String.contains?(value, "@") do
      :ok
    else
      {:error, "value must be an email address for source 'email'"}
    end
  end

  defp validate_value_format(_, _), do: :ok

  defp validate_claim_format(source, claim)
       when source in ["email", "email_domain"] and is_binary(claim) do
    if String.trim(claim) == "" do
      :ok
    else
      {:error, "claim is not allowed for source '#{source}'"}
    end
  end

  defp validate_claim_format(_, _), do: :ok
end
