defmodule ServiceRadarWebNGWeb.DashboardPackageLive.Preferences do
  @moduledoc """
  Merging rules for per-user dashboard renderer preferences.

  A dashboard package renderer reads its preferences from
  `host.instance.settings.preferences` (see `DashboardWasmHost`). Two sources
  feed that map: the dashboard instance's own settings, which act as a seed for
  users who have set nothing, and the signed-in user's stored preferences, which
  win.

  This lives apart from the LiveView because the key handling is fiddly enough
  to be worth testing on its own: instance settings may carry string or atom
  keys depending on how they were persisted, while the renderer only ever reads
  the string form.
  """

  @preferences_key "preferences"

  @doc """
  Merge a user's stored preferences into a dashboard instance's settings map.

  User values win over the instance's seed. The result always carries string
  keys under `"preferences"`.

      iex> alias ServiceRadarWebNGWeb.DashboardPackageLive.Preferences
      iex> Preferences.merge(%{"preferences" => %{"a" => 1, "b" => 2}}, %{"b" => 3})
      %{"preferences" => %{"a" => 1, "b" => 3}}

      iex> alias ServiceRadarWebNGWeb.DashboardPackageLive.Preferences
      iex> Preferences.merge(%{preferences: %{"a" => 1}}, %{"b" => 2})
      %{"preferences" => %{"a" => 1, "b" => 2}}
  """
  @spec merge(map(), map()) :: map()
  def merge(settings, preferences) when is_map(settings) and is_map(preferences) do
    if map_size(preferences) == 0 do
      settings
    else
      settings
      |> Map.delete(:preferences)
      |> Map.put(@preferences_key, Map.merge(seed(settings), preferences))
    end
  end

  def merge(settings, _preferences) when is_map(settings), do: settings
  def merge(_settings, _preferences), do: %{}

  @doc """
  Put a single key into a preference map, returning the updated map.

  Blank keys are ignored: the renderer trims before pushing, but the event is
  client-supplied and must not be able to create an empty-string key.
  """
  @spec put(map(), String.t(), term()) :: map()
  def put(preferences, key, value) when is_map(preferences) and is_binary(key) do
    case String.trim(key) do
      "" -> preferences
      trimmed -> Map.put(preferences, trimmed, value)
    end
  end

  def put(preferences, _key, _value) when is_map(preferences), do: preferences
  def put(_preferences, _key, _value), do: %{}

  defp seed(settings) do
    case Map.get(settings, @preferences_key) || Map.get(settings, :preferences) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end
end
