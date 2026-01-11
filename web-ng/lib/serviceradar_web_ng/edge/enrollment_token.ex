defmodule ServiceRadarWebNG.Edge.EnrollmentToken do
  @moduledoc """
  Generates and verifies self-contained enrollment tokens for collector onboarding.

  ## Token Format

  The token is a base64-encoded JSON object containing:
  - `u` - API base URL
  - `p` - Package ID
  - `t` - Secret token (hashed version stored in DB)
  - `e` - Expiry timestamp (Unix seconds)

  ## Usage Flow

  1. Customer creates a collector package in the UI
  2. System generates an enrollment token with embedded URL and secret
  3. Customer installs the collector binary from package repo
  4. Customer runs: `serviceradar-cli enroll --token <token>`
  5. CLI decodes token, calls `GET {url}/api/enroll/{package_id}?token={secret}`
  6. API returns NATS creds, config, and optional TLS certs
  7. CLI writes files to `/etc/serviceradar/` and starts the service

  ## Security

  - Token secret is hashed (SHA256) before storing in DB
  - Token expires after 24 hours by default
  - Token can only be used once (marked as downloaded after use)
  """

  @default_expiry_hours 24

  @doc """
  Generates a new enrollment token for a collector package.

  Returns `{token_string, token_hash, secret}` where:
  - `token_string` is the self-contained base64-encoded token to give to user
  - `token_hash` is the SHA256 hash to store in the database
  - `secret` is the raw secret (in case you need to regenerate with a new package_id)
  """
  @spec generate(String.t(), keyword()) :: {String.t(), String.t(), String.t()}
  def generate(package_id, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    expiry_hours = Keyword.get(opts, :expiry_hours, @default_expiry_hours)

    # Generate a secure random secret (or use provided one)
    secret = Keyword.get(opts, :secret) || generate_secret()

    # Calculate expiry timestamp
    expiry =
      DateTime.utc_now() |> DateTime.add(expiry_hours * 3600, :second) |> DateTime.to_unix()

    # Build the token payload
    payload = %{
      "u" => base_url,
      "p" => package_id,
      "t" => secret,
      "e" => expiry
    }

    # Encode as JSON then base64
    token_string =
      payload
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    # Hash the secret for storage
    token_hash = hash_secret(secret)

    {token_string, token_hash, secret}
  end

  @doc """
  Generates a secure random secret.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  Decodes an enrollment token to extract its components.

  Returns `{:ok, %{base_url: url, package_id: id, secret: secret, expires_at: datetime}}`
  or `{:error, reason}`.
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode(token_string) do
    with {:ok, json} <- Base.url_decode64(token_string, padding: false),
         {:ok, payload} <- Jason.decode(json),
         {:ok, result} <- extract_payload(payload) do
      {:ok, result}
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies a secret against a stored hash.
  """
  @spec verify_secret(String.t(), String.t()) :: boolean()
  def verify_secret(secret, stored_hash) do
    computed_hash = hash_secret(secret)
    Plug.Crypto.secure_compare(computed_hash, stored_hash)
  end

  @doc """
  Checks if a token has expired based on its expiry timestamp.
  """
  @spec expired?(DateTime.t()) :: boolean()
  def expired?(expires_at) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Generates a CLI command for the given token.
  """
  @spec cli_command(String.t()) :: String.t()
  def cli_command(token) do
    "serviceradar-cli enroll --token #{token}"
  end

  @doc """
  Returns the expiry DateTime for a given token.
  """
  @spec expiry_datetime(keyword()) :: DateTime.t()
  def expiry_datetime(opts \\ []) do
    expiry_hours = Keyword.get(opts, :expiry_hours, @default_expiry_hours)
    DateTime.utc_now() |> DateTime.add(expiry_hours * 3600, :second)
  end

  # Private functions

  defp extract_payload(payload) do
    with {:ok, base_url} <- Map.fetch(payload, "u"),
         {:ok, package_id} <- Map.fetch(payload, "p"),
         {:ok, secret} <- Map.fetch(payload, "t"),
         {:ok, expiry_unix} <- Map.fetch(payload, "e"),
         {:ok, expires_at} <- DateTime.from_unix(expiry_unix) do
      {:ok,
       %{
         base_url: base_url,
         package_id: package_id,
         secret: secret,
         expires_at: expires_at
       }}
    else
      :error -> {:error, :missing_fields}
      {:error, _} -> {:error, :invalid_expiry}
    end
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp default_base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "https://api.serviceradar.cloud")
  end
end
