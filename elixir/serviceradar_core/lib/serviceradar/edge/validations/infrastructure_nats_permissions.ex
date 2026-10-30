defmodule ServiceRadar.Edge.Validations.InfrastructureNatsPermissions do
  @moduledoc "Explicit allow and deny lists; an empty allow list means no permission."
  use Ash.Resource.Validation

  @keys ["publish", "subscribe", "publish_deny", "subscribe_deny"]

  @impl true
  def validate(changeset, _opts, _context) do
    permissions = Ash.Changeset.get_argument(changeset, :permissions)

    if valid?(permissions),
      do: :ok,
      else:
        {:error,
         field: :permissions,
         message: "requires explicit publish/subscribe subject lists and optional deny lists"}
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp valid?(permissions) when is_map(permissions) do
    normalized = Map.new(permissions, fn {key, value} -> {to_string(key), value} end)

    map_size(normalized) == map_size(permissions) &&
      Enum.all?(Map.keys(normalized), &(&1 in @keys)) &&
      Map.has_key?(normalized, "publish") && Map.has_key?(normalized, "subscribe") &&
      Enum.all?(Map.values(normalized), fn subjects ->
        is_list(subjects) && Enum.all?(subjects, &valid_subject?/1)
      end)
  end

  defp valid?(_), do: false

  defp valid_subject?(subject) when is_binary(subject) do
    tokens = String.split(subject, ".")

    byte_size(subject) in 1..512 && !String.match?(subject, ~r/\s/u) &&
      Enum.all?(Enum.with_index(tokens), fn {token, index} ->
        token == "*" || (token == ">" && index == length(tokens) - 1) ||
          (token != "" && !String.contains?(token, ["*", ">", <<0>>]))
      end)
  end

  defp valid_subject?(_), do: false
end
