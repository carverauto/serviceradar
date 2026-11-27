defmodule ServiceRadarUI do
  @moduledoc """
  ServiceRadar's shared Phoenix design system.

  The package has four parts:

    * `ServiceRadarUI.Components` - buttons, badges, panels, alerts, flash,
      modal, tabs, dropdown, table, pagination, spinner, form fields and icons.
    * `ServiceRadarUI.Shell` - skip link, sticky top bar, footer, theme toggle
      and flash group.
    * `ServiceRadarUI.Charts` - sparkline, area, bar, donut and gauge charts
      rendered as SVG on the server, plus a hook-driven live sparkline.
    * `ServiceRadarUI.Maps` - an offline world map driven by the `SrWorldMap`
      hook.

  CSS ships in `priv/css` (`tokens.css` and `components.css`) and the LiveView
  hooks ship prebuilt in `priv/static/serviceradar_ui.js`. See the README for
  how to wire both into an application.

  Use everything at once with:

      use ServiceRadarUI

  which imports the components, shell, charts and maps. Import modules
  individually (or alias them) if their function names collide with your
  application's own `CoreComponents`.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ServiceRadarUI.Components
      import ServiceRadarUI.Shell
      import ServiceRadarUI.Charts
      import ServiceRadarUI.Maps
    end
  end

  @doc """
  Pushes new data to a hook-driven element (`ServiceRadarUI.Charts.live_sparkline/1`,
  `ServiceRadarUI.Maps.world_map/1`) without re-rendering it.

  The hook on the element with the given DOM `id` receives `payload` through
  the `"sr:update:<id>"` event.

      socket
      |> ServiceRadarUI.push_update("edge-map", %{points: points})
  """
  @spec push_update(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push_update(socket, id, payload) when is_binary(id) and is_map(payload) do
    Phoenix.LiveView.push_event(socket, update_event(id), payload)
  end

  @doc """
  The event name `push_update/3` uses for the element `id`.
  """
  @spec update_event(String.t()) :: String.t()
  def update_event(id) when is_binary(id), do: "sr:update:" <> id

  @doc """
  Translates a form error with the configured translator.

  Configure a `{module, function}` that takes `{message, opts}` and returns a
  string, for example a Gettext-backed function in your application:

      config :serviceradar_ui, :error_translator, {MyAppWeb.CoreComponents, :translate_error}

  Without a translator, `%{key}` placeholders in the message are interpolated
  from `opts`.
  """
  @spec translate_error({String.t(), keyword() | map()} | String.t()) :: String.t()
  def translate_error({msg, opts} = error) when is_binary(msg) do
    case Application.get_env(:serviceradar_ui, :error_translator) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [error])

      nil ->
        interpolate(msg, opts)
    end
  end

  def translate_error(msg) when is_binary(msg), do: msg

  defp interpolate(msg, opts) do
    Enum.reduce(opts, msg, fn
      {key, value}, acc when is_atom(key) or is_binary(key) ->
        String.replace(acc, "%{#{key}}", to_string_safe(value))

      _other, acc ->
        acc
    end)
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_string_safe(value), do: inspect(value)
end
