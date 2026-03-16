defmodule ServiceRadarWebNG.Mailer do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all

  use Swoosh.Mailer, otp_app: :serviceradar_web_ng
end
