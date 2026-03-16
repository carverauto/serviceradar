defmodule ServiceRadarWebNG.Accounts.UserNotifier do
  @moduledoc """
  Notification module for user-related emails.

  Sends emails for confirmation and settings updates.
  """

  import Swoosh.Email

  alias ServiceRadarWebNG.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    # Handle both string and ci_string email types
    recipient_string = if is_binary(recipient), do: recipient, else: to_string(recipient)

    email =
      new()
      |> to(recipient_string)
      |> from(mailer_from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp mailer_from do
    mailer_config = Application.get_env(:serviceradar_web_ng, ServiceRadarWebNG.Mailer, [])

    from_name = Keyword.get(mailer_config, :from_name, "ServiceRadarWebNG")
    from_email = Keyword.get(mailer_config, :from_email, "contact@example.com")

    {from_name, from_email}
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    This link will expire in 1 hour.

    ==============================
    """)
  end
end
