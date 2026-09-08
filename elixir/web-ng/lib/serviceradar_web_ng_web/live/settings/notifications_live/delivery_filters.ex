defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters do
  @moduledoc """
  Parses and serialises the Delivery Log filter set.

  Filters live in the URL so a filtered view is shareable - "here is why you were
  not paged" is a link an operator sends to a colleague, not a sequence of clicks
  they describe. `parse/1` reads the query string and `to_params/1` writes it
  back, and the two are inverses for every filter the UI offers.

  Every enumerated filter is mapped through
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation`, which is a
  literal whitelist: an unrecognised `state` or `suppression_reason` drops the
  filter instead of becoming one. Free-text ids are kept as strings and checked
  for UUID shape before they reach a query, so a crafted value produces an empty
  result rather than a cast error the page cannot render.

  The default is deliberately **unfiltered by state**. The Delivery Log's whole
  purpose is that suppressed and skipped rows are visible alongside sent ones; a
  default that hid them would recreate the failure the log exists to fix.
  """

  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation

  @uuid_regex ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @windows [
    {"1h", 1},
    {"6h", 6},
    {"24h", 24},
    {"7d", 168},
    {"30d", 720},
    {"all", nil}
  ]

  @default_window "24h"

  @type t :: %{
          alert_id: String.t() | nil,
          channel_id: String.t() | nil,
          route_id: String.t() | nil,
          state: atom() | nil,
          suppression_reason: atom() | nil,
          execution_route: atom() | nil,
          payload_format: atom() | nil,
          provider_version: integer() | nil,
          is_test: boolean() | nil,
          window: String.t()
        }

  @doc "The empty filter set: every state, every reason, the default window."
  @spec empty() :: t()
  def empty do
    %{
      alert_id: nil,
      channel_id: nil,
      route_id: nil,
      state: nil,
      suppression_reason: nil,
      execution_route: nil,
      payload_format: nil,
      provider_version: nil,
      is_test: nil,
      window: @default_window
    }
  end

  @doc "The time-window options, most recent first."
  @spec window_options() :: [{String.t(), String.t()}]
  def window_options do
    [
      {"Last hour", "1h"},
      {"Last 6 hours", "6h"},
      {"Last 24 hours", "24h"},
      {"Last 7 days", "7d"},
      {"Last 30 days", "30d"},
      {"All time", "all"}
    ]
  end

  @doc "Reads the filter set out of `handle_params` params."
  @spec parse(term()) :: t()
  def parse(params) when is_map(params) do
    %{
      alert_id: uuid(params["alert_id"]),
      channel_id: uuid(params["channel_id"]),
      route_id: uuid(params["route_id"]),
      state: Presentation.parse_delivery_state(params["state"]),
      suppression_reason: Presentation.parse_suppression_reason(params["suppression_reason"]),
      execution_route: Presentation.parse_execution_route(params["execution_route"]),
      payload_format: Presentation.parse_payload_format(params["payload_format"]),
      provider_version: positive_integer(params["provider_version"]),
      is_test: Presentation.parse_boolean(params["is_test"]),
      window: window(params["window"])
    }
  end

  def parse(_params), do: empty()

  @doc """
  Serialises a filter set back into query params, omitting everything unset so a
  shared link carries only what the operator actually chose.
  """
  @spec to_params(t()) :: %{optional(String.t()) => String.t()}
  def to_params(filters) when is_map(filters) do
    %{
      "alert_id" => filters[:alert_id],
      "channel_id" => filters[:channel_id],
      "route_id" => filters[:route_id],
      "state" => stringify(filters[:state]),
      "suppression_reason" => stringify(filters[:suppression_reason]),
      "execution_route" => stringify(filters[:execution_route]),
      "payload_format" => stringify(filters[:payload_format]),
      "provider_version" => stringify(filters[:provider_version]),
      "is_test" => stringify(filters[:is_test]),
      "window" => window_param(filters[:window])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  def to_params(_filters), do: %{}

  @doc "Whether any filter is set beyond the default window."
  @spec any?(t()) :: boolean()
  def any?(filters) when is_map(filters) do
    filters
    |> to_params()
    |> Map.delete("window")
    |> map_size()
    |> Kernel.>(0) or filters[:window] != @default_window
  end

  def any?(_filters), do: false

  @doc """
  The lower bound of the selected window, or `nil` for "all time".

  `now` is passed in rather than read from the clock so the bound a query used is
  the bound a test can assert.
  """
  @spec since(t(), DateTime.t()) :: DateTime.t() | nil
  def since(filters, %DateTime{} = now) do
    case hours(filters[:window]) do
      nil -> nil
      count -> DateTime.add(now, -count * 3600, :second)
    end
  end

  defp hours(window) do
    case List.keyfind(@windows, to_string(window || @default_window), 0) do
      {_key, hours} -> hours
      nil -> 24
    end
  end

  defp window(value) when is_binary(value) do
    if List.keymember?(@windows, value, 0), do: value, else: @default_window
  end

  defp window(_value), do: @default_window

  defp window_param(@default_window), do: nil
  defp window_param(value) when is_binary(value), do: value
  defp window_param(_value), do: nil

  defp uuid(value) when is_binary(value) do
    trimmed = String.trim(value)
    if Regex.match?(@uuid_regex, trimmed), do: trimmed
  end

  defp uuid(_value), do: nil

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
