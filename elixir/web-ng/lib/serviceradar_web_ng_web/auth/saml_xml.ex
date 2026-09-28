defmodule ServiceRadarWebNGWeb.Auth.SAMLXml do
  @moduledoc """
  The one XML parser configuration used for SAML metadata and responses.

  Neither a SAML response nor IdP metadata has any reason to carry a DTD, so
  documents are parsed with `dtd: :none`: an entity declaration is an error and
  external resources are never fetched. That closes XML external entity reads
  and entity-expansion bombs alike, which is what the `esaml` XXE advisory
  waiver in `.deps_audit_ignore` relies on -- `esaml` is used only for
  `:xmerl_dsig` over documents parsed here, never for its own decoding.

  Parsing is namespace-conformant so XPath queries built with
  `SweetXml.add_namespace/3` match on namespace URI, whatever prefix the IdP
  used.
  """

  @doc """
  Parses `xml` into an xmerl document, or returns `{:error, :invalid_xml}`.
  """
  @spec parse(String.t()) :: {:ok, tuple()} | {:error, :invalid_xml}
  def parse(xml) when is_binary(xml) do
    {:ok, SweetXml.parse(xml, dtd: :none, quiet: true, namespace_conformant: true)}
  rescue
    # `dtd: :none` raises on an entity declaration.
    _error in [RuntimeError] -> {:error, :invalid_xml}
  catch
    # xmerl reports malformed documents by exiting.
    :exit, _reason -> {:error, :invalid_xml}
  end

  def parse(_xml), do: {:error, :invalid_xml}
end
