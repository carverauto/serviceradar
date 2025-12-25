defmodule ServiceRadarWebNG.Accounts.UserToken do
  @moduledoc """
  Token schema for session and email verification tokens.

  Uses Ecto schema directly for token management, separate from
  the Ash User resource. This allows for custom token handling
  while the User operations are handled by Ash.
  """

  use Ecto.Schema
  import Ecto.Query
  alias ServiceRadarWebNG.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  # Primary key is bigint in database, use default Ecto id
  @foreign_key_type :binary_id

  schema "ng_users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    field :user_id, Ecto.UUID

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = Map.get(user, :authenticated_at) || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).

  Note: This query joins with ng_users table directly since we need to
  return user data with the authenticated_at from the token.
  """
  def verify_session_token_query(token) do
    query =
      from t in by_token_and_context_query(token, "session"),
        join: u in "ng_users",
        on: u.id == t.user_id,
        where: t.inserted_at > ago(@session_validity_in_days, "day"),
        select: {
          %{
            id: u.id,
            email: u.email,
            hashed_password: u.hashed_password,
            confirmed_at: u.confirmed_at,
            tenant_id: u.tenant_id,
            role: u.role,
            display_name: u.display_name,
            authenticated_at: t.authenticated_at
          },
          t.inserted_at
        }

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    # Handle both string and atom email types
    sent_to_string = if is_binary(sent_to), do: sent_to, else: to_string(sent_to)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to_string,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user_data, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks if the token is being used within
  15 minutes. The context of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from t in by_token_and_context_query(hashed_token, "login"),
            join: u in "ng_users",
            on: u.id == t.user_id,
            where: t.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: t.sent_to == u.email,
            select: {
              %{
                id: u.id,
                email: u.email,
                hashed_password: u.hashed_password,
                confirmed_at: u.confirmed_at,
                tenant_id: u.tenant_id,
                role: u.role,
                display_name: u.display_name,
                authenticated_at: fragment("NULL::timestamp")
              },
              t
            }

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
