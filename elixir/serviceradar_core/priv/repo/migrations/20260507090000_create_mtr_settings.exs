defmodule ServiceRadar.Repo.Migrations.CreateMtrSettings do
  @moduledoc """
  Creates deployment-scoped MTR diagnostics settings.
  """

  use Ecto.Migration

  @default_retention_days 30

  def change do
    create table(:mtr_settings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:mtr_retention_days, :integer, null: false, default: @default_retention_days)
      add(:mtr_default_history_window, :string, null: false, default: "last_30d")
      add(:mtr_history_page_size_default, :integer, null: false, default: 50)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:mtr_settings, :mtr_settings_retention_days_check,
        check: "mtr_retention_days BETWEEN 1 AND 395",
        prefix: "platform"
      )
    )

    create(
      constraint(:mtr_settings, :mtr_settings_page_size_check,
        check: "mtr_history_page_size_default BETWEEN 10 AND 200",
        prefix: "platform"
      )
    )

    execute(
      """
      INSERT INTO platform.mtr_settings
        (mtr_retention_days, mtr_default_history_window, mtr_history_page_size_default, inserted_at, updated_at)
      SELECT
        #{configured_retention_days()},
        'last_30d',
        50,
        now(),
        now()
      WHERE NOT EXISTS (SELECT 1 FROM platform.mtr_settings)
      """,
      "DELETE FROM platform.mtr_settings"
    )
  end

  defp configured_retention_days do
    "MTR_RETENTION_DAYS"
    |> System.get_env()
    |> parse_days(@default_retention_days)
    |> max(1)
    |> min(395)
  end

  defp parse_days(nil, default), do: default
  defp parse_days("", default), do: default

  defp parse_days(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} -> days
      _ -> default
    end
  end
end
