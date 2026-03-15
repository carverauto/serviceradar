defmodule ServiceRadar.Identity.Senders.EmailDelivery do
  @moduledoc false

  import Swoosh.Email

  @from {"ServiceRadar", "noreply@serviceradar.cloud"}

  def deliver(user, subject, url, opts) do
    email_string = to_string(user.email)
    display_name = user.display_name || email_string

    new()
    |> to({display_name, email_string})
    |> from(@from)
    |> subject(subject)
    |> html_body(render_html_body(url, opts))
    |> text_body(render_text_body(url, opts))
    |> ServiceRadar.Mailer.deliver()
  end

  def base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
  end

  defp render_html_body(url, opts) do
    """
    <h2>#{Keyword.fetch!(opts, :heading)}</h2>
    <p>#{Keyword.fetch!(opts, :intro)}</p>
    <p><a href="#{url}" target="_blank">#{Keyword.fetch!(opts, :link_label)}</a></p>
    <p>#{Keyword.fetch!(opts, :expiry)}</p>
    <p>#{Keyword.fetch!(opts, :ignore)}</p>
    """
  end

  defp render_text_body(url, opts) do
    """
    #{Keyword.fetch!(opts, :heading)}

    #{Keyword.fetch!(opts, :intro)}

    #{url}

    #{Keyword.fetch!(opts, :expiry)}

    #{Keyword.fetch!(opts, :ignore)}
    """
  end
end
