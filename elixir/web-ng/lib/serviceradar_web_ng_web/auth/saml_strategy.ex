defmodule ServiceRadarWebNGWeb.Auth.SAMLStrategy do
  @moduledoc """
  Dynamic SAML 2.0 configuration from auth_settings.

  This module provides runtime SAML configuration for Samly based on the
  current AuthSettings. It supports:

  - Dynamic IdP metadata loading (URL or XML)
  - Custom SP entity ID configuration
  - Attribute mapping from SAML assertions

  ## Configuration

  SAML settings are stored in AuthSettings:
  - `saml_idp_metadata_url` - URL to fetch IdP metadata
  - `saml_idp_metadata_xml` - IdP metadata XML (if URL not available)
  - `saml_sp_entity_id` - Service Provider entity ID

  ## SP Metadata

  The SP metadata is available at `/auth/saml/metadata` and should be
  registered with your IdP.
  """

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OutboundFetch

  require Logger

  @doc """
  Returns true if SAML is enabled and configured.
  """
  def enabled? do
    case ConfigCache.get_settings() do
      {:ok, settings} -> saml_enabled?(settings)
      {:error, _} -> false
    end
  end

  @doc """
  Gets the current SAML configuration for Samly.

  Returns `{:ok, config}` if SAML is configured, `{:error, reason}` otherwise.
  """
  def get_config do
    case ConfigCache.get_settings() do
      {:ok, settings} ->
        if saml_enabled?(settings) do
          build_config(settings)
        else
          {:error, :not_enabled}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets the SP entity ID from configuration or generates a default.
  """
  def get_sp_entity_id do
    case ConfigCache.get_settings() do
      {:ok, %{saml_sp_entity_id: entity_id}} when is_binary(entity_id) and entity_id != "" ->
        entity_id

      _ ->
        # Default to the base URL
        ServiceRadarWebNGWeb.Endpoint.url()
    end
  end

  @doc """
  Gets the Assertion Consumer Service (ACS) URL.
  """
  def get_acs_url do
    ServiceRadarWebNGWeb.Endpoint.url() <> "/auth/saml/consume"
  end

  @doc """
  Gets the SP metadata URL.
  """
  def get_metadata_url do
    ServiceRadarWebNGWeb.Endpoint.url() <> "/auth/saml/metadata"
  end

  defp saml_enabled?(%{is_enabled: true, mode: :active_sso, provider_type: :saml}), do: true
  defp saml_enabled?(_), do: false

  defp build_config(settings) do
    idp_metadata = get_idp_metadata(settings)

    case idp_metadata do
      {:ok, metadata} ->
        with {:ok, entity_id} <- extract_idp_entity_id(metadata) do
          config = %{
            idp_metadata: metadata,
            idp_entity_id: entity_id,
            sp_entity_id: settings.saml_sp_entity_id || get_sp_entity_id(),
            acs_url: get_acs_url(),
            assertion_max_validity_seconds:
              Application.get_env(
                :serviceradar_web_ng,
                :saml_assertion_max_validity_seconds,
                300
              ),
            claim_mappings:
              settings.claim_mappings ||
                %{
                  "email" => "email",
                  "name" => "name",
                  "sub" => "sub"
                },
            pinned_cert_fingerprints: settings.saml_pinned_cert_fingerprints || []
          }

          {:ok, config}
        end

      {:error, _} = error ->
        error
    end
  end

  defp get_idp_metadata(%{saml_idp_metadata_xml: xml}) when is_binary(xml) and xml != "" do
    {:ok, {:xml, xml}}
  end

  defp get_idp_metadata(%{saml_idp_metadata_url: url}) when is_binary(url) and url != "" do
    # Cache the metadata for 1 hour
    cache_key = "saml_idp_metadata:#{url}"

    case ConfigCache.get_cached(cache_key) do
      {:ok, cached} ->
        {:ok, {:xml, cached}}

      :miss ->
        case fetch_metadata(url) do
          {:ok, xml} ->
            ConfigCache.put_cached(cache_key, xml, ttl: to_timeout(hour: 1))
            {:ok, {:xml, xml}}

          {:error, _} = error ->
            error
        end
    end
  end

  defp get_idp_metadata(_), do: {:error, :no_idp_metadata}

  defp fetch_metadata(url) do
    case OutboundFetch.get(url) do
      {:ok, response} ->
        case response do
          %{status: 200, body: body} when is_binary(body) ->
            {:ok, body}

          %{status: status} ->
            Logger.error("Failed to fetch SAML IdP metadata: status=#{status}")
            {:error, :metadata_fetch_failed}
        end

      {:error, :disallowed_scheme} ->
        {:error, :metadata_fetch_failed}

      {:error, :disallowed_host} ->
        {:error, :metadata_fetch_failed}

      {:error, :invalid_url} ->
        {:error, :metadata_fetch_failed}

      {:error, :dns_resolution_failed} ->
        {:error, :metadata_fetch_failed}

      {:error, reason} ->
        Logger.error("Failed to fetch SAML IdP metadata: #{inspect(reason)}")
        {:error, :metadata_fetch_failed}
    end
  end

  defp extract_idp_entity_id({:xml, xml}) when is_binary(xml) do
    import SweetXml

    with {:ok, doc} <- safe_sweetxml_parse(xml) do
      entity_id =
        xpath(
          doc,
          ~x"//md:EntityDescriptor/@entityID"s,
          namespace_conformant: true,
          namespaces: [md: "urn:oasis:names:tc:SAML:2.0:metadata"]
        )

      if is_binary(entity_id) and String.trim(entity_id) != "" do
        {:ok, String.trim(entity_id)}
      else
        {:ok, nil}
      end
    end
  end

  defp extract_idp_entity_id(_), do: {:error, :invalid_metadata}

  defp safe_sweetxml_parse(xml_string) do
    options = [
      quiet: true,
      xmerl_options: [
        fetch_fun: &reject_external_resource/2
      ]
    ]

    {:ok, SweetXml.parse(xml_string, options)}
  rescue
    _ -> {:error, :invalid_metadata}
  catch
    :exit, _ -> {:error, :invalid_metadata}
  end

  defp reject_external_resource(_ext_spec, _scanner_state), do: {:error, :disabled_for_security}
end
