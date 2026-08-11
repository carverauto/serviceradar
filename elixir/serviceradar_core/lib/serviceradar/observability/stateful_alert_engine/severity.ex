defmodule ServiceRadar.Observability.StatefulAlertEngine.Severity do
  @moduledoc """
  Severity resolution for stateful alert events: deriving the OCSF severity id
  from rule overrides (or the source record when `severity_from: source`),
  mapping severity names to ids, and the inverse log-level projection.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Record

  alias ServiceRadar.EventWriter.OCSF

  @severity_name_to_id %{
    "emergency" => OCSF.severity_fatal(),
    "fatal" => OCSF.severity_fatal(),
    "critical" => OCSF.severity_critical(),
    "error" => OCSF.severity_high(),
    "high" => OCSF.severity_high(),
    "warning" => OCSF.severity_medium(),
    "medium" => OCSF.severity_medium(),
    "notice" => OCSF.severity_low(),
    "low" => OCSF.severity_low(),
    "info" => OCSF.severity_informational(),
    "informational" => OCSF.severity_informational()
  }

  def severity_id(alert_overrides, record) do
    overrides = alert_overrides || %{}

    severity =
      if severity_from_source?(overrides) do
        source_severity(record)
      else
        overrides["severity"] ||
          overrides["severity_id"] ||
          overrides[:severity] ||
          overrides[:severity_id] ||
          :warning
      end

    resolve_severity_id(severity)
  end

  def severity_from_source?(overrides) when is_map(overrides) do
    severity_from = overrides["severity_from"] || overrides[:severity_from]
    severity_from in ["source", "source_event", :source, :source_event]
  end

  def severity_from_source?(_overrides), do: false

  def source_severity(record) do
    record_field_value(record, "severity_number") ||
      record_field_value(record, "severity_text") ||
      :warning
  end

  def resolve_severity_id(severity) when is_integer(severity) and severity in 1..6, do: severity

  def resolve_severity_id(severity) when is_atom(severity) do
    severity
    |> Atom.to_string()
    |> resolve_severity_id()
  end

  def resolve_severity_id(severity) when is_binary(severity) do
    Map.get(@severity_name_to_id, String.downcase(severity), OCSF.severity_medium())
  end

  def resolve_severity_id(_), do: OCSF.severity_medium()

  def log_level_for_severity(severity_id) do
    case severity_id do
      6 -> "fatal"
      5 -> "critical"
      4 -> "error"
      3 -> "warning"
      2 -> "notice"
      1 -> "info"
      _ -> "unknown"
    end
  end
end
