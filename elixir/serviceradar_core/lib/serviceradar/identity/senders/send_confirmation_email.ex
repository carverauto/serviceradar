defmodule ServiceRadar.Identity.Senders.SendConfirmationEmail do
  @moduledoc """
  Sends email confirmation emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  use AshAuthentication.Sender
  import Swoosh.Email

  @impl true
  def send(user, token, _opts) do
    url = build_confirmation_url(token)
    email_string = to_string(user.email)
    display_name = user.display_name || email_string

    email =
      new()
      |> to({display_name, email_string})
      |> from({"ServiceRadar", "noreply@serviceradar.cloud"})
      |> subject("Confirm your ServiceRadar email")
      |> html_body("""
      <h2>Confirm your email</h2>
      <p>Click the link below to confirm your email address:</p>
      <p><a href="#{url}" target="_blank">Confirm Email</a></p>
      <p>This link will expire in 7 days.</p>
      <p>If you didn't create a ServiceRadar account, you can safely ignore this email.</p>
      """)
      |> text_body("""
      Confirm your email

      Click the link below to confirm your email address:

      #{url}

      This link will expire in 7 days.

      If you didn't create a ServiceRadar account, you can safely ignore this email.
      """)

    ServiceRadar.Mailer.deliver(email)
  end

  defp build_confirmation_url(token) do
    base_url = Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
    "#{base_url}/auth/user/confirm?token=#{token}"
  end
end
