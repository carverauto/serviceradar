defmodule ServiceRadar.Identity.Senders.SendConfirmationEmail do
  @moduledoc """
  Sends email confirmation emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  alias ServiceRadar.Identity.Senders.EmailDelivery

  @doc """
  Sends a confirmation email to the user.

  ## Parameters
    - user: The user struct with email and display_name
    - token: The confirmation token to include in the URL
    - opts: Additional options (currently unused)

  ## Returns
    - {:ok, email} on success
    - {:error, reason} on failure
  """
  def send(user, token, _opts \\ []) do
    EmailDelivery.deliver(
      user,
      "Confirm your ServiceRadar email",
      build_confirmation_url(token),
      heading: "Confirm your email",
      intro: "Click the link below to confirm your email address:",
      link_label: "Confirm Email",
      expiry: "This link will expire in 7 days.",
      ignore: "If you didn't create a ServiceRadar account, you can safely ignore this email."
    )
  end

  defp build_confirmation_url(token) do
    "#{EmailDelivery.base_url()}/auth/confirm-email/#{token}"
  end
end
