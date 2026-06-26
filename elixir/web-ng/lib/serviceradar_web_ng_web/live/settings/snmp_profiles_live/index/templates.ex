defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Templates do
  @moduledoc false
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate

  def create_custom_template(scope, attrs) do
    SNMPOIDTemplate
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  def parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 1.0
    end
  end

  def parse_float(value) when is_float(value), do: value
  def parse_float(value) when is_integer(value), do: value / 1
  def parse_float(_), do: 1.0
end
