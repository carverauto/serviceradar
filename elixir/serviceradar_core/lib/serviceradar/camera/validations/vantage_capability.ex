defmodule ServiceRadar.Camera.Validations.VantageCapability do
  @moduledoc """
  Validates `ServiceRadar.Camera.VantagePipeline` capability syntax and ensures
  `:external_worker` pipelines declare a valid capability token.
  """

  use Ash.Resource.Validation

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Changes.InvalidAttribute

  @capability_regex ~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/

  @doc "Regex matching valid Vantage capability identifiers."
  @spec capability_regex() :: Regex.t()
  def capability_regex, do: @capability_regex

  @impl true
  def validate(changeset, _opts, _context) do
    runner = proposed_value(changeset, :runner)
    capability = proposed_value(changeset, :capability)
    validate_runner_capability(runner, capability)
  end

  @impl true
  def atomic(changeset, opts, context) do
    if match?(%OriginalDataNotAvailable{}, changeset.data) and
         (pending_change?(changeset, :runner) or pending_change?(changeset, :capability)) and
         not (pending_change?(changeset, :runner) and pending_change?(changeset, :capability)) do
      {:not_atomic,
       "validating external_worker capability requires current runner and capability"}
    else
      validate(changeset, opts, context)
    end
  end

  defp validate_runner_capability(:external_worker, capability) do
    if is_binary(capability) and Regex.match?(@capability_regex, capability) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :capability,
         message:
           "is required and must match ^[a-z0-9][a-z0-9._-]{0,127}$ when runner is external_worker"
       )}
    end
  end

  defp validate_runner_capability(_runner, nil), do: :ok

  defp validate_runner_capability(_runner, capability) do
    if is_binary(capability) and Regex.match?(@capability_regex, capability) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :capability,
         message: "must match ^[a-z0-9][a-z0-9._-]{0,127}$"
       )}
    end
  end

  defp pending_change?(changeset, field) do
    Keyword.has_key?(changeset.atomics, field) or
      match?({:ok, _}, Ash.Changeset.fetch_change(changeset, field))
  end

  defp proposed_value(changeset, field) do
    case Keyword.fetch(changeset.atomics, field) do
      {:ok, value} ->
        value

      :error ->
        case Ash.Changeset.fetch_change(changeset, field) do
          {:ok, value} -> value
          :error -> existing_value(changeset, field)
        end
    end
  end

  defp existing_value(changeset, field) do
    case Ash.Changeset.get_data(changeset, field) do
      %OriginalDataNotAvailable{} -> nil
      value -> value
    end
  rescue
    _ -> nil
  end
end
