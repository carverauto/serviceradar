defmodule ServiceRadar.NetworkDiscovery.Changes.NormalizeControllerBaseUrl do
  @moduledoc false

  alias Ash.Changeset

  @valid_schemes ["http", "https"]

  def change(changeset, required_path) do
    case Changeset.get_attribute(changeset, :base_url) do
      value when is_binary(value) ->
        normalize(changeset, value, required_path)

      _ ->
        changeset
    end
  end

  defp normalize(changeset, raw_value, required_path) do
    raw_value
    |> String.trim()
    |> ensure_scheme()
    |> URI.parse()
    |> normalize_uri(changeset, required_path)
  end

  defp ensure_scheme(value) do
    if String.match?(value, ~r/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//) do
      value
    else
      "https://" <> value
    end
  end

  defp normalize_uri(%URI{} = uri, changeset, required_path) do
    scheme = uri.scheme
    host = uri.host

    if scheme in @valid_schemes and is_binary(host) and host != "" do
      do_normalize_uri(uri, changeset, required_path)
    else
      Changeset.add_error(changeset,
        field: :base_url,
        message: "must be a valid http(s) URL"
      )
    end
  end

  defp do_normalize_uri(%URI{} = uri, changeset, required_path) do
    case normalize_path(changeset, uri.path || "", required_path) do
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

        Changeset.change_attribute(changeset, :base_url, normalized)

      {:error, error_changeset} ->
        error_changeset
    end
  end

  defp normalize_path(changeset, path, required_path) do
    normalized =
      path
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      normalized in ["", "."] ->
        {:ok, required_path}

      normalized == required_path ->
        {:ok, required_path}

      true ->
        {:error,
         Changeset.add_error(changeset,
           field: :base_url,
           message: "must be a host URL or include #{required_path}"
         )}
    end
  end
end
