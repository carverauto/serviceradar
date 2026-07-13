defmodule ServiceRadarWebNGWeb.Plugs.RateLimit.Bodies do
  @moduledoc """
  Pre-built `:json_body_builder` helpers for
  `ServiceRadarWebNGWeb.Plugs.RateLimit` pipelines that need to
  match an existing client contract instead of the plug's default
  `{"error":"rate_limited","retry_after":N}` shape.

  Each helper is a 1-arity function that takes the `retry_after`
  in seconds and returns iodata for the 429 response body.
  """

  @doc """
  CLI device-auth shape:
  `{"error":"rate_limited","error_description":"Too many ..."}`.

  Matches the legacy body emitted by
  `cli_auth_controller.rate_limited_response/2` so parsed
  `serviceradar-cli` device-flow clients keep working.
  """
  @spec cli_device_auth(pos_integer()) :: iodata()
  def cli_device_auth(_retry_after) do
    Jason.encode!(%{
      error: "rate_limited",
      error_description: "Too many authentication attempts. Please try again later."
    })
  end

  @doc false
  def automation_callback(_retry_after), do: ~s({"error":"callback_denied"})
end
