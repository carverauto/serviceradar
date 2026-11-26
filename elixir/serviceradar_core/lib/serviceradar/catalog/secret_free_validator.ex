defmodule ServiceRadar.Catalog.SecretFreeValidator do
  @moduledoc """
  Pre-flight secret-free scanner for Solution Packs, browser exports, and GitOps
  pushes (`2.4`, Decision 2).

  Guarantees that no pack directory tree, `.srpack` archive, HTTP export payload,
  or GitOps blob contains:
  - Forbidden secret-bearing JSON keys (`password`, `secret`, `secret_payload`,
    `encrypted_secret_payload`, `private_key`, `api_key`, `access_token`,
    `session_token`, `auth_passphrase`, `priv_passphrase`, `community_string`,
    `credential_secret_id`, `credential_rule_id`, etc.)
  - Literal HTTP authentication headers (`Authorization: Bearer ...`, `Basic ...`)
  - Known API token / PAT / key literals (`ghp_`, `github_pat_`, `glpat-`,
    `xoxb-`, `AKIA...`, JWT `eyJ...`, PEM `-----BEGIN ... PRIVATE KEY-----`)
  """

  @type violation :: %{
          file: String.t(),
          path: String.t(),
          code: String.t(),
          message: String.t()
        }

  @forbidden_keys MapSet.new(~w(
    password
    encrypted_password
    secret
    client_secret
    secret_key
    secret_payload
    encrypted_secret_payload
    private_key
    ssh_private_key
    api_key
    api_token
    access_token
    refresh_token
    bearer_token
    auth_token
    session_token
    access_key
    access_key_id
    secret_access_key
    auth_passphrase
    priv_passphrase
    community_string
    credential_secret_id
    credential_rule_id
    credentials_encrypted
    pat
    github_token
    gitlab_token
    gitea_token
  ))

  @forbidden_header_names MapSet.new(~w(
    authorization
    proxy-authorization
    x-api-key
    api-key
    x-auth-token
    x-gitlab-token
  ))

  @placeholder_only_regex ~r/\A\s*(?:\{\{\s*[a-zA-Z0-9._-]+\s*\}\}|\$\{\s*[a-zA-Z0-9._-]+\s*\})\s*\z/

  @token_patterns [
    {"pem_private_key", ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
     "contains PEM private key material"},
    {"github_pat", ~r/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}\b/,
     "contains a GitHub personal access token literal"},
    {"github_fine_grained_pat", ~r/\bgithub_pat_[A-Za-z0-9_]{16,}\b/,
     "contains a GitHub fine-grained PAT literal"},
    {"gitlab_pat", ~r/\bglpat-[A-Za-z0-9_-]{12,}\b/,
     "contains a GitLab personal access token literal"},
    {"slack_token", ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, "contains a Slack token literal"},
    {"aws_access_key", ~r/\bAKIA[0-9A-Z]{16}\b/, "contains an AWS access key ID literal"},
    {"jwt_literal", ~r/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
     "contains a JWT token literal"},
    {"auth_header_literal",
     ~r/(?i)\bauthorization\s*:\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)\s+(?!\{\{|\$\{)\S+/,
     "contains a literal Authorization header value"}
  ]

  @header_auth_scheme_regex ~r/(?i)\A\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)\s+(?!\{\{|\$\{)\S+/

  @doc """
  Scans an entire pack file tree (`%{relative_path => binary_or_decoded_map}`) and
  returns `:ok` or `{:error, [violation()]}` identifying every offending file and
  JSON path.
  """
  @spec validate_pack_tree(map()) :: :ok | {:error, [violation()]}
  def validate_pack_tree(file_map) when is_map(file_map) do
    violations =
      file_map
      |> Enum.sort_by(fn {path, _} -> to_string(path) end)
      |> Enum.flat_map(fn {raw_path, content} ->
        path = to_string(raw_path)
        scan_pack_entry(path, content)
      end)

    case violations do
      [] -> :ok
      list -> {:error, list}
    end
  end

  @doc """
  Scans a decoded JSON term for forbidden secret keys and token literals.
  """
  @spec validate_value(term(), String.t()) :: :ok | {:error, [violation()]}
  def validate_value(value, file \\ "document.json") do
    case scan_json(value, file, "$", false) do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  @doc """
  Scans raw text (e.g., `README.md` or `assets/*.svg`) for embedded token/key literals.
  """
  @spec validate_text(String.t(), String.t()) :: :ok | {:error, [violation()]}
  def validate_text(text, file \\ "README.md") when is_binary(text) do
    case scan_string_literals(text, file, "$") do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  defp scan_pack_entry(path, content) when is_map(content) do
    content
    |> scan_json(path, "$", false)
    |> Enum.reverse()
  end

  defp scan_pack_entry(path, content) when is_binary(content) do
    lower_path = String.downcase(path)

    cond do
      String.ends_with?(lower_path, ".json") ->
        case Jason.decode(content) do
          {:ok, decoded} ->
            decoded
            |> scan_json(path, "$", false)
            |> Enum.reverse()

          {:error, err} ->
            [
              %{
                file: path,
                path: "$",
                code: "invalid_json",
                message: "failed to parse JSON (#{Exception.message(err)})"
              }
            ]
        end

      String.ends_with?(lower_path, ".js") or String.ends_with?(lower_path, ".mjs") ->
        if String.valid?(content) do
          content
          |> scan_string_literals(path, "$")
          |> Enum.reverse()
        else
          [
            %{
              file: path,
              path: "$",
              code: "invalid_utf8",
              message: "JavaScript file #{inspect(path)} must be valid UTF-8"
            }
          ]
        end

      true ->
        content
        |> scan_string_literals(path, "$")
        |> Enum.reverse()
    end
  end

  defp scan_pack_entry(path, _other) do
    [
      %{
        file: path,
        path: "$",
        code: "invalid_entry_type",
        message: "pack file content must be a UTF-8 binary or decoded JSON map"
      }
    ]
  end

  defp scan_json(map, file, json_path, in_headers?) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.reduce([], fn {raw_key, val}, acc ->
      key = to_string(raw_key)
      normalized_key = normalize_key(key)
      child_path = "#{json_path}.#{key}"
      child_in_headers? = in_headers? or normalized_key == "headers"

      acc =
        cond do
          MapSet.member?(@forbidden_keys, normalized_key) ->
            [
              %{
                file: file,
                path: child_path,
                code: "forbidden_secret_key",
                message:
                  "forbidden secret or instance credential key #{inspect(key)}; use abstract credential_slots instead"
              }
              | acc
            ]

          in_headers? and MapSet.member?(@forbidden_header_names, String.downcase(key)) and
              not placeholder_only?(val) ->
            [
              %{
                file: file,
                path: child_path,
                code: "forbidden_auth_header",
                message:
                  "literal authentication header #{inspect(key)} is forbidden; bind a credential_slot instead"
              }
              | acc
            ]

          in_headers? and is_binary(val) and Regex.match?(@header_auth_scheme_regex, val) ->
            [
              %{
                file: file,
                path: child_path,
                code: "forbidden_auth_header_value",
                message: "literal credential scheme in HTTP header value is forbidden"
              }
              | acc
            ]

          true ->
            acc
        end

      scan_json(val, file, child_path, child_in_headers?) ++ acc
    end)
  end

  defp scan_json(list, file, json_path, in_headers?) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, idx}, acc ->
      scan_json(item, file, "#{json_path}[#{idx}]", in_headers?) ++ acc
    end)
  end

  defp scan_json(str, file, json_path, _in_headers?) when is_binary(str) do
    if placeholder_only?(str) do
      []
    else
      scan_string_literals(str, file, json_path)
    end
  end

  defp scan_json(_scalar, _file, _json_path, _in_headers?), do: []

  defp scan_string_literals(str, file, json_path) do
    Enum.reduce(@token_patterns, [], fn {code, regex, desc}, acc ->
      if Regex.match?(regex, str) do
        [
          %{
            file: file,
            path: json_path,
            code: code,
            message: "secret-free violation: #{desc}"
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp normalize_key(key) do
    key
    |> String.trim()
    |> String.replace("-", "_")
    |> String.downcase()
  end

  defp placeholder_only?(val) when is_binary(val), do: Regex.match?(@placeholder_only_regex, val)
  defp placeholder_only?(%{"$pack_param" => param}) when is_binary(param), do: true
  defp placeholder_only?(_other), do: false
end
