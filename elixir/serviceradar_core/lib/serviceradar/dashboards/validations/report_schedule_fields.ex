defmodule ServiceRadar.Dashboards.Validations.ReportScheduleFields do
  @moduledoc """
  Validates dashboard report schedule cadence and recipient fields.
  """

  use Ash.Resource.Validation

  alias Oban.Cron.Expression

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_recipients(Ash.Changeset.get_attribute(changeset, :recipients)),
         :ok <- validate_cron(Ash.Changeset.get_attribute(changeset, :cron)) do
      validate_timezone(Ash.Changeset.get_attribute(changeset, :timezone))
    end
  end

  defp validate_recipients(recipients) when is_list(recipients) and recipients != [] do
    case Enum.find(recipients, &(not valid_email?(&1))) do
      nil ->
        :ok

      invalid ->
        {:error, field: :recipients, message: "contains invalid email #{inspect(invalid)}"}
    end
  end

  defp validate_recipients(_recipients),
    do: {:error, field: :recipients, message: "must include at least one recipient"}

  defp validate_cron(cron) when is_binary(cron) do
    case Expression.parse(cron) do
      {:ok, _expr} -> :ok
      _ -> {:error, field: :cron, message: "is not a valid 5-field cron expression"}
    end
  end

  defp validate_cron(_cron), do: {:error, field: :cron, message: "is required"}

  defp validate_timezone(timezone) when timezone in ["UTC", "Etc/UTC"], do: :ok

  defp validate_timezone(timezone) when is_binary(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), normalize_timezone(timezone)) do
      {:ok, _datetime} -> :ok
      _ -> {:error, field: :timezone, message: "is not a valid timezone"}
    end
  end

  defp validate_timezone(_timezone), do: {:error, field: :timezone, message: "is required"}

  defp valid_email?(value) when is_binary(value), do: value =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  defp valid_email?(_value), do: false

  defp normalize_timezone("UTC"), do: "Etc/UTC"
  defp normalize_timezone(timezone), do: timezone
end
