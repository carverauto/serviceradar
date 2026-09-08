defmodule ServiceRadar.Mailer do
  @moduledoc """
  Mailer module for sending emails from ServiceRadar.

  Uses Swoosh adapters. Configure in your application's config:

      config :serviceradar_core, ServiceRadar.Mailer,
        adapter: Swoosh.Adapters.Local  # or your preferred adapter
  """

  use Swoosh.Mailer, otp_app: :serviceradar_core
end
