defmodule ServiceRadar.Identity.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends magic link authentication emails.

  Uses Swoosh for email delivery via the configured mailer.
  """

  use AshAuthentication.Sender
  import Swoosh.Email

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Identity.Tenant

  require Ash.Query

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
    fetch_tenant_by_id(tenant_id)
  end

  defp resolve_tenant(_user_or_email, opts) do
    opts
    |> Keyword.get(:tenant)
    |> fetch_tenant_by_schema()
  end

  defp fetch_tenant_by_id(tenant_id) when is_binary(tenant_id) do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Tenant{} = tenant} -> tenant
      _ -> nil
    end
  end

  defp fetch_tenant_by_id(_), do: nil

  defp fetch_tenant_by_schema(schema) when is_binary(schema) do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, tenants} when is_list(tenants) ->
        Enum.find(tenants, fn tenant ->
          TenantSchemas.schema_for_tenant(tenant) == schema
        end)

      _ ->
        nil
    end
  end

  defp fetch_tenant_by_schema(_), do: nil
end
