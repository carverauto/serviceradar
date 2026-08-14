defmodule ServiceRadar.CompositeChecks.Validations.InputConfig do
  @moduledoc """
  Validates the `config` map against the input's `kind`.

  This is the per-kind half of the extension seam: adding an input kind means
  adding a clause here and a resolver module, and nothing else.
  """

  use Ash.Resource.Validation

  @supported_value_types ["boolean"]

  # Delegate rather than returning a bare `:ok`: a validation whose `atomic/3`
  # returns `:ok` is skipped when the action runs atomically, which would let an
  # invalid config through on update.
  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    config = Ash.Changeset.get_attribute(changeset, :config) || %{}

    with :ok <- validate_kind(kind, config) do
      validate_max_age(config)
    end
  end

  defp validate_kind(:vantage_point, config) do
    case Map.get(config, "agent_id") do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        :ok

      _ ->
        {:error, field: :config, message: "vantage_point config requires a non-empty agent_id"}
    end
  end

  defp validate_kind(:device_metadata, config) do
    path = Map.get(config, "path")
    value_type = Map.get(config, "value_type")

    cond do
      not (is_binary(path) and path != "") ->
        {:error, field: :config, message: "device_metadata config requires a non-empty path"}

      value_type not in @supported_value_types ->
        {:error,
         field: :config,
         message:
           "device_metadata config value_type must be one of: " <>
             Enum.join(@supported_value_types, ", ")}

      true ->
        :ok
    end
  end

  defp validate_kind(_kind, _config), do: :ok

  defp validate_max_age(config) do
    case Map.fetch(config, "max_age_seconds") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, seconds} when is_integer(seconds) and seconds > 0 -> :ok
      {:ok, _} -> {:error, field: :config, message: "max_age_seconds must be a positive integer"}
    end
  end
end
