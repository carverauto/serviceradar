defmodule ServiceRadar.Notifications.TimeZone do
  @moduledoc """
  Compatibility API for notification scheduling timezone behavior.

  Timezone resolution is owned by `ServiceRadar.TimeZone` so user preferences
  and notification schedules share PostgreSQL's installed IANA catalog.
  """

  defdelegate supported?(timezone), to: ServiceRadar.TimeZone
  defdelegate supported?(timezone, opts), to: ServiceRadar.TimeZone
  defdelegate local_datetime(now, timezone), to: ServiceRadar.TimeZone
  defdelegate local_datetime(now, timezone, opts), to: ServiceRadar.TimeZone
end
