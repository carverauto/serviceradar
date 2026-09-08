defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.FormHelpers do
  @moduledoc false
  def get_form_value(form, field, default) do
    case form[field] do
      %Phoenix.HTML.FormField{value: value} when not is_nil(value) ->
        to_string(value)

      _ ->
        default
    end
  end
end
