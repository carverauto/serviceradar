defmodule ServiceRadar.EventWriter.LogSeverity do
  @moduledoc """
  Maps a log's syslog/GELF `level` to a normalized OTEL severity.
  """

  @severity_aliases %{
    "fatal" => "FATAL",
    "critical" => "FATAL",
    "emergency" => "FATAL",
    "alert" => "FATAL",
    "very high" => "FATAL",
    "very_high" => "FATAL",
    "high" => "ERROR",
    "error" => "ERROR",
    "medium" => "WARN",
    "warn" => "WARN",
    "warning" => "WARN",
    "low" => "INFO",
    "info" => "INFO",
    "informational" => "INFO",
    "notice" => "INFO",
    "unknown" => "INFO",
    "debug" => "DEBUG",
    "trace" => "DEBUG"
  }

  @doc """
  Maps a numeric syslog/GELF `level` (0-7) to a normalized OTEL
  `{severity_text, severity_number}` tuple.

  The numbers are the canonical OTEL severity-number base values and are kept in
  lockstep with the bundled `syslog_severity` Zen rule
  (`priv/zen/rules/syslog_severity.json`) so the in-Zen and Elixir-fallback
  ingestion paths agree. Non-numeric levels fall back to text aliasing.
  """
  @spec from_level(term()) :: {String.t(), non_neg_integer()}
  def from_level(level) do
    case parse_numeric(level) do
      {:ok, value} ->
        case value do
          v when v in [0, 1, 2] -> {"FATAL", 21}
          3 -> {"ERROR", 19}
          4 -> {"WARN", 15}
          v when v in [5, 6] -> {"INFO", 9}
          7 -> {"DEBUG", 5}
          _ -> {"INFO", 9}
        end

      :error ->
        from_text(to_string(level))
    end
  end

  defp from_text(text) do
    severity = Map.get(@severity_aliases, String.downcase(String.trim(text)), "INFO")
    {severity, number_for_text(severity)}
  end

  defp number_for_text("FATAL"), do: 23
  defp number_for_text("ERROR"), do: 19
  defp number_for_text("WARN"), do: 15
  defp number_for_text("DEBUG"), do: 7
  defp number_for_text(_text), do: 11

  defp parse_numeric(value) when is_integer(value), do: {:ok, value}
  defp parse_numeric(value) when is_float(value), do: {:ok, round(value)}

  defp parse_numeric(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end

  defp parse_numeric(_), do: :error
end
