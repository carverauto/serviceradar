defmodule ServiceRadar.Identity.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends password reset emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  alias ServiceRadar.Identity.Senders.EmailDelivery

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
    EmailDelivery.deliver(
      user,
      "Reset your ServiceRadar password",
      build_reset_url(token),
      heading: "Reset your password",
      intro: "Click the link below to reset your ServiceRadar password:",
      link_label: "Reset Password",
      expiry: "This link will expire in 1 hour.",
      ignore: "If you didn't request a password reset, you can safely ignore this email."
    )
  end

  defp build_reset_url(token) do
    "#{EmailDelivery.base_url()}/auth/password-reset/#{token}"
  end
end
