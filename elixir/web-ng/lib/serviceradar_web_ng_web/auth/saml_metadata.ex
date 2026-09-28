defmodule ServiceRadarWebNGWeb.Auth.SAMLMetadata do
  @moduledoc """
  Reads the fields the SAML service provider needs from IdP metadata XML.

  Metadata is parsed with external entity resolution disabled, and in
  namespace-conformant mode so that queries match elements by namespace URI
  rather than by the prefix a particular IdP chose (`md:`, `saml2md:`, a
  default namespace, ...).
  """

  import SweetXml, only: [sigil_x: 2, add_namespace: 3, xpath: 2]

  alias ServiceRadarWebNGWeb.Auth.SAMLXml

  @metadata_ns "urn:oasis:names:tc:SAML:2.0:metadata"
  @dsig_ns "http://www.w3.org/2000/09/xmldsig#"
  @redirect_binding "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"

  @doc """
  Returns the IdP `entityID`, `{:ok, nil}` when the metadata carries none, or
  `{:error, :invalid_metadata}` when the XML cannot be parsed safely.
  """
  @spec entity_id(String.t()) :: {:ok, String.t() | nil} | {:error, :invalid_metadata}
  def entity_id(xml) when is_binary(xml) do
    with {:ok, doc} <- parse(xml) do
      entity_id =
        doc
        |> xpath(md(~x"//md:EntityDescriptor[md:IDPSSODescriptor]/@entityID"ls))
        |> List.first("")
        |> String.trim()

      {:ok, if(entity_id == "", do: nil, else: entity_id)}
    end
  end

  def entity_id(_xml), do: {:error, :invalid_metadata}

  @doc """
  Returns the IdP's HTTP-Redirect `SingleSignOnService` location.
  """
  @spec sso_redirect_url(String.t()) ::
          {:ok, String.t()} | {:error, :sso_url_not_found | :invalid_metadata}
  def sso_redirect_url(xml) when is_binary(xml) do
    with {:ok, doc} <- parse(xml) do
      spec =
        "//md:IDPSSODescriptor/md:SingleSignOnService[@Binding='#{@redirect_binding}']/@Location"
        |> SweetXml.sigil_x(~c"s")
        |> md()

      case doc |> xpath(spec) |> String.trim() do
        "" -> {:error, :sso_url_not_found}
        url -> {:ok, url}
      end
    end
  end

  def sso_redirect_url(_xml), do: {:error, :invalid_metadata}

  @doc """
  Returns the DER-encoded X.509 certificates the IdP signs with.

  Certificates on a `KeyDescriptor use="signing"` are preferred; when there are
  none, certificates on a `KeyDescriptor` without a `use` attribute (which
  covers signing and encryption) are used.
  """
  @spec signing_certificates(String.t()) :: {:ok, [binary()]} | {:error, :invalid_metadata}
  def signing_certificates(xml) when is_binary(xml) do
    with {:ok, doc} <- parse(xml) do
      encoded =
        case key_descriptor_certificates(doc, "[@use='signing']") do
          [] -> key_descriptor_certificates(doc, "[not(@use)]")
          signing -> signing
        end

      certificates =
        encoded
        |> Enum.map(&String.replace(&1, ~r/\s+/, ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn encoded ->
          case Base.decode64(encoded) do
            {:ok, der} -> [der]
            :error -> []
          end
        end)

      {:ok, certificates}
    end
  end

  def signing_certificates(_xml), do: {:error, :invalid_metadata}

  defp key_descriptor_certificates(doc, predicate) do
    path =
      "//md:IDPSSODescriptor/md:KeyDescriptor#{predicate}" <>
        "/ds:KeyInfo/ds:X509Data/ds:X509Certificate/text()"

    spec =
      path
      |> SweetXml.sigil_x(~c"ls")
      |> md()
      |> add_namespace("ds", @dsig_ns)

    xpath(doc, spec)
  end

  defp parse(xml) do
    case SAMLXml.parse(xml) do
      {:ok, doc} -> {:ok, doc}
      {:error, :invalid_xml} -> {:error, :invalid_metadata}
    end
  end

  defp md(spec), do: add_namespace(spec, "md", @metadata_ns)
end
