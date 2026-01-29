defmodule ServiceRadar.Identity.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends password reset emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  import Swoosh.Email

  @doc """
  Sends a password reset email to the user.

  ## Parameters
    - user: The user struct with email and display_name
    - token: The reset token to include in the URL
    - opts: Additional options (currently unused)

  ## Returns
    - {:ok, email} on success
    - {:error, reason} on failure
  """
  def send(user, token, _opts \\ []) do
    url = build_reset_url(token)

    email_string = to_string(user.email)
    display_name = user.display_name || email_string

    email =
      new()
      |> to({display_name, email_string})
      |> from({"ServiceRadar", "noreply@serviceradar.cloud"})
      |> subject("Reset your ServiceRadar password")
      |> html_body("""
      <h2>Reset your password</h2>
      <p>Click the link below to reset your ServiceRadar password:</p>
      <p><a href="#{url}" target="_blank">Reset Password</a></p>
      <p>This link will expire in 1 hour.</p>
      <p>If you didn't request a password reset, you can safely ignore this email.</p>
      """)
      |> text_body("""
      Reset your password

      Click the link below to reset your ServiceRadar password:

      #{url}

      This link will expire in 1 hour.

      If you didn't request a password reset, you can safely ignore this email.
      """)

    ServiceRadar.Mailer.deliver(email)
  end

  defp build_reset_url(token) do
    base_url = Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
    "#{base_url}/auth/password-reset/#{token}"
  end
end
