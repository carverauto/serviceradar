defmodule ServiceRadar.Identity.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends magic link authentication emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  use AshAuthentication.Sender
  import Swoosh.Email

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Tenant

  require Ash.Query
  require Logger

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  @impl true
  def send(user_or_email, token, opts) do
    # Build the magic link URL
    url = build_magic_link_url(user_or_email, token, opts)

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

  defp build_magic_link_url(user_or_email, token, opts) do
    base_uri = base_uri()
    tenant = resolve_tenant(user_or_email, opts)

    uri =
      case tenant do
        %Tenant{is_platform_tenant: true} ->
          base_uri

        %Tenant{slug: slug} ->
          tenant_base_domain =
            Application.get_env(:serviceradar_web_ng, :tenant_base_domain, base_uri.host)

          %{base_uri | host: "#{slug}.#{tenant_base_domain}"}

        nil ->
          Logger.warning("Unable to resolve tenant for magic link URL; falling back to base URL")
          base_uri

        _ ->
          raise "Unable to resolve tenant for magic link URL"
      end

    %{uri | path: "/auth/user/magic_link", query: URI.encode_query(%{"token" => token})}
    |> URI.to_string()
  end

  defp base_uri do
    base_url = Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
    URI.parse(base_url)
  end

  defp resolve_tenant(%{tenant_id: tenant_id}, _opts) when is_binary(tenant_id) do
    fetch_tenant_by_id(tenant_id) || default_tenant()
  end

  defp resolve_tenant(_user_or_email, opts) do
    opts
    |> Keyword.get(:tenant)
    |> fetch_tenant_by_schema()
    |> case do
      %Tenant{} = tenant -> tenant
      _ -> tenant_from_base_uri() || default_tenant()
    end
  end

  defp tenant_from_base_uri do
    base_uri = base_uri()
    base_host = base_uri.host

    case tenant_slug_from_host(base_host) do
      slug when is_binary(slug) -> fetch_tenant_by_slug(slug)
      _ -> nil
    end
  end

  defp tenant_slug_from_host(nil), do: nil

  defp tenant_slug_from_host(host) when is_binary(host) do
    base_domain = Application.get_env(:serviceradar_web_ng, :tenant_base_domain, host)

    if is_binary(base_domain) do
      suffix = "." <> base_domain
      downcased_host = String.downcase(host)

      cond do
        downcased_host == String.downcase(base_domain) ->
          nil

        String.ends_with?(downcased_host, suffix) ->
          String.trim_trailing(downcased_host, suffix)

        true ->
          nil
      end
    else
      nil
    end
  end

  defp default_tenant do
    configured =
      Application.get_env(:serviceradar_core, :default_tenant_id, @zero_uuid)

    platform_tenant_id = Application.get_env(:serviceradar_core, :platform_tenant_id)

    tenant_id =
      if is_nil(configured) or configured == @zero_uuid do
        platform_tenant_id
      else
        configured
      end

    fetch_tenant_by_id(tenant_id) || fetch_platform_tenant()
  end

  defp fetch_tenant_by_id(tenant_id) when is_binary(tenant_id) do
    # Platform actor for authentication routing (before tenant is confirmed)
    actor = SystemActor.platform(:magic_link_sender)

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %Tenant{} = tenant} -> tenant
      _ -> nil
    end
  end

  defp fetch_tenant_by_id(_), do: nil

  defp fetch_tenant_by_slug(slug) when is_binary(slug) do
    actor = SystemActor.platform(:magic_link_sender)

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %Tenant{} = tenant} -> tenant
      _ -> nil
    end
  end

  defp fetch_tenant_by_slug(_), do: nil

  defp fetch_platform_tenant do
    actor = SystemActor.platform(:magic_link_sender)

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(is_platform_tenant: true)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %Tenant{} = tenant} -> tenant
      _ -> nil
    end
  end

  defp fetch_tenant_by_schema(schema) when is_binary(schema) do
    case extract_tenant_slug(schema) do
      {:ok, slug} ->
        fetch_tenant_by_slug(slug)

      :error ->
        fetch_tenant_by_schema_fallback(schema)
    end
  end

  defp fetch_tenant_by_schema(_), do: nil

  defp extract_tenant_slug("tenant_" <> slug), do: {:ok, slug}
  defp extract_tenant_slug(_), do: :error

  defp fetch_tenant_by_schema_fallback(schema) do
    # Platform actor for authentication routing (before tenant is confirmed)
    actor = SystemActor.platform(:magic_link_sender)

    # Fallback: query tenants and match by slug
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, tenants} when is_list(tenants) ->
        Enum.find(tenants, fn tenant ->
          "tenant_#{tenant.slug}" == schema
        end)

      _ ->
        nil
    end
  end
end
