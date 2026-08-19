defmodule ServiceradarSecret.FileProvider do
  @moduledoc """
  One file per logical name, which is how Kubernetes and Docker present secrets.

  The mount path is a constant for the same reason the instance mount is one: the platform decides
  what to put there, and a settable path would be a second thing able to disagree with the
  environment.
  """

  alias ServiceradarSecret.Secret

  @mounted_secrets_dir "/etc/serviceradar/secrets"
  def mounted_secrets_dir, do: @mounted_secrets_dir

  @local_secrets_subdir ".serviceradar/secrets"
  def local_secrets_subdir, do: @local_secrets_subdir

  defstruct [:dir, :label]

  @type t :: %__MODULE__{dir: String.t(), label: String.t()}

  def new(dir, label), do: %__MODULE__{dir: dir, label: label}
  def mounted, do: new(@mounted_secrets_dir, "file(#{@mounted_secrets_dir})")

  @doc """
  The file store the environment selects.

  `localhost` reads a repository-local directory because a developer machine has no platform
  mounting anything into /etc, and requiring one would make the first run fail on a path rather
  than on anything they did.

  HOME is a PLATFORM variable, not ServiceRadar configuration, so reading it adds no setting
  anyone can point somewhere else -- there is deliberately no ServiceRadar variable for the store
  location, because a settable path is a second thing able to disagree with the environment.

  One caveat belongs here rather than in a caller: Bazel REWRITES HOME to a per-test scratch
  directory, so under a test action this resolves inside the sandbox and finds nothing. The fix
  is to restore the platform value with `--test_env=HOME` in the profile that runs those tests,
  NOT to introduce a path setting.

  Mirrors `FileProvider::for_kind` in //config/manager_secret/rust.
  """
  @spec for_kind(String.t()) :: t()
  def for_kind("localhost") do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        dir = Path.join(home, @local_secrets_subdir)
        new(dir, "file(#{dir})")

      # Failing loudly naming a path beats silently reading nothing.
      _ ->
        mounted()
    end
  end

  def for_kind(_kind), do: mounted()

  def describe(%__MODULE__{label: label}), do: label

  def resolve(%__MODULE__{dir: dir, label: label}, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, raw} ->
        # A trailing newline is an artefact of how the file was written, not part of the secret.
        # Everything else is preserved: a password may legitimately contain spaces.
        case Secret.new(String.trim_trailing(raw, "\n") |> String.trim_trailing("\r")) do
          {:ok, secret} -> {:ok, secret}
          :error -> {:error, {:unresolvable, name, label}}
        end

      {:error, :enoent} ->
        {:error, {:unresolvable, name, label}}

      {:error, reason} ->
        {:error, {:provider_failed, name, label, inspect(reason)}}
    end
  end
end
