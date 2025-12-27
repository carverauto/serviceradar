defmodule ServiceRadar.Identity.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends magic link authentication emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  use AshAuthentication.Sender
  import Swoosh.Email

  @impl true
  def send(user_or_email, token, _opts) do
    # Build the magic link URL
    url = build_magic_link_url(token)

    # Handle both user struct and email string (for registration flow)
    {email_string, display_name} = extract_email_info(user_or_email)

    email =
      new()
      |> to({display_name, email_string})
      |> from({"ServiceRadar", "noreply@serviceradar.cloud"})
      |> subject("Sign in to ServiceRadar")
      |> html_body("""
      <h2>Sign in to ServiceRadar</h2>
      <p>Click the link below to sign in to your account:</p>
      <p><a href="#{url}" target="_blank">Sign in to ServiceRadar</a></p>
      <p>This link will expire in 15 minutes.</p>
      <p>If you didn't request this email, you can safely ignore it.</p>
      """)
      |> text_body("""
      Sign in to ServiceRadar

      Click the link below to sign in to your account:

      #{url}

      This link will expire in 15 minutes.

      If you didn't request this email, you can safely ignore it.
      """)

    ServiceRadar.Mailer.deliver(email)
  end

  # Handle user struct (existing user)
  defp extract_email_info(%{email: email} = user) do
    email_string = to_string(email)
    display_name = Map.get(user, :display_name) || email_string
    {email_string, display_name}
  end

  # Handle email string (new user during registration)
  defp extract_email_info(email) when is_binary(email) do
    {email, email}
  end

  # Handle Ash.CiString
  defp extract_email_info(email) do
    email_string = to_string(email)
    {email_string, email_string}
  end

  defp build_magic_link_url(token) do
    base_url = Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
    "#{base_url}/auth/user/magic_link?token=#{token}"
  end
end
