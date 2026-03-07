defmodule ServiceRadar.NetworkDiscovery.Changes.NormalizeMikrotikBaseUrl do
  @moduledoc """
  Normalizes and validates MikroTik RouterOS REST API URLs.

  Accepted inputs:
  - Host URL only, e.g. `https://192.168.88.1`
  - REST base URL, e.g. `https://192.168.88.1/rest`
  """

  use Ash.Resource.Change

  @required_path "/rest"
  @valid_schemes ["http", "https"]

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      value when is_binary(value) ->
        normalize(changeset, value)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp normalize(changeset, raw_value) do
    raw_value
    |> String.trim()
    |> ensure_scheme()
    |> URI.parse()
    |> normalize_uri(changeset)
  end

  defp ensure_scheme(value) do
    if String.match?(value, ~r/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//) do
      value
    else
      "https://" <> value
    end
  end

  defp normalize_uri(%URI{} = uri, changeset) do
    scheme = uri.scheme
    host = uri.host

    if scheme in @valid_schemes and is_binary(host) and host != "" do
      do_normalize_uri(uri, changeset)
    else
      Ash.Changeset.add_error(changeset,
        field: :base_url,
        message: "must be a valid http(s) URL"
      )
    end
  end

  defp do_normalize_uri(%URI{} = uri, changeset) do
    case normalize_path(changeset, uri.path || "") do
      {:ok, path} ->
        normalized =
          %URI{
            scheme: uri.scheme,
            userinfo: nil,
            host: uri.host,
            port: uri.port,
            path: path,
            query: nil,
            fragment: nil
          }
          |> URI.to_string()

        Ash.Changeset.change_attribute(changeset, :base_url, normalized)

      {:error, error_changeset} ->
        error_changeset
    end
  end

  defp normalize_path(changeset, path) do
    normalized =
      path
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      normalized in ["", "."] ->
        {:ok, @required_path}

      normalized == @required_path ->
        {:ok, @required_path}

      true ->
        {:error,
         Ash.Changeset.add_error(changeset,
           field: :base_url,
           message: "must be a host URL or include #{@required_path}"
         )}
    end
  end
end
