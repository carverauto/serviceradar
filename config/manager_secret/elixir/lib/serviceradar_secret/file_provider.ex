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

  defstruct [:dir, :label]

  @type t :: %__MODULE__{dir: String.t(), label: String.t()}

  def new(dir, label), do: %__MODULE__{dir: dir, label: label}
  def mounted, do: new(@mounted_secrets_dir, "file(#{@mounted_secrets_dir})")

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
