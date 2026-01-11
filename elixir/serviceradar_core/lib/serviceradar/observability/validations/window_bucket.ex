defmodule ServiceRadar.Observability.Validations.WindowBucket do
  @moduledoc """
  Validates window/bucket/threshold constraints for stateful alert rules.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    window = Ash.Changeset.get_attribute(changeset, :window_seconds)
    bucket = Ash.Changeset.get_attribute(changeset, :bucket_seconds)
    threshold = Ash.Changeset.get_attribute(changeset, :threshold)

    cond do
      is_integer(window) and window <= 0 ->
        {:error, field: :window_seconds, message: "must be greater than zero"}

      is_integer(bucket) and bucket <= 0 ->
        {:error, field: :bucket_seconds, message: "must be greater than zero"}

      is_integer(threshold) and threshold <= 0 ->
        {:error, field: :threshold, message: "must be greater than zero"}

      is_integer(window) and is_integer(bucket) and rem(window, bucket) != 0 ->
        {:error, field: :bucket_seconds, message: "must divide window_seconds"}

      true ->
        :ok
    end
  end
end
