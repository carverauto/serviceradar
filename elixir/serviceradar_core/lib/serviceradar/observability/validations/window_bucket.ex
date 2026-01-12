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

    with :ok <- validate_positive(:window_seconds, window),
         :ok <- validate_positive(:bucket_seconds, bucket),
         :ok <- validate_positive(:threshold, threshold),
         :ok <- validate_bucket_divides_window(window, bucket) do
      :ok
    end
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(_field, nil), do: :ok
  defp validate_positive(field, _value), do: {:error, field: field, message: "must be greater than zero"}

  defp validate_bucket_divides_window(window, bucket)
       when is_integer(window) and is_integer(bucket) and rem(window, bucket) != 0 do
    {:error, field: :bucket_seconds, message: "must divide window_seconds"}
  end

  defp validate_bucket_divides_window(_window, _bucket), do: :ok
end
