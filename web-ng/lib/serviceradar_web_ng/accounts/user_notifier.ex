defmodule ServiceRadarWebNG.Accounts.UserNotifier do
  @moduledoc """
  Notification module for user-related emails.

  Sends emails for login, confirmation, and settings updates.
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
      |> from({"ServiceRadarWebNG", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
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
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    # Check if user is confirmed (works with both Ash User and maps)
    case user do
      %{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
