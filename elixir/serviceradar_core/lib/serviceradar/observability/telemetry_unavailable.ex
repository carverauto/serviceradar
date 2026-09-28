defmodule ServiceRadar.Observability.TelemetryUnavailable do
  @moduledoc """
  Raised when a telemetry reader has no warehouse implementation but the
  warehouse is the active backend, so serving the CNPG table would return
  history frozen at the switch.
  """

  use Splode.Error, fields: [:resource], class: :forbidden

  def message(error) do
    "Telemetry for #{inspect(error.resource)} is unavailable with StarRocks enabled"
  end
end

defimpl AshJsonApi.ToJsonApiError, for: ServiceRadar.Observability.TelemetryUnavailable do
  def to_json_api_error(error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 503,
      code: "telemetry_unavailable_with_starrocks",
      title: "Unavailable",
      detail: ServiceRadar.Observability.TelemetryUnavailable.message(error)
    }
  end
end
