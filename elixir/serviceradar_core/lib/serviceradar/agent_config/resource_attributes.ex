defmodule ServiceRadar.AgentConfig.ResourceAttributes do
  @moduledoc false

  @config_types [:sweep, :sysmon, :snmp, :mapper]

  @spec config_types() :: [:sweep | :sysmon | :snmp | :mapper]
  def config_types, do: @config_types

  defmacro config_type_attribute(description) do
    config_types = @config_types

    quote bind_quoted: [description: description, config_types: config_types] do
      attribute :config_type, :atom do
        allow_nil?(false)
        public?(true)
        constraints(one_of: config_types)
        description(description)
      end
    end
  end

  defmacro config_snapshot_attributes(opts) do
    compiled_config_description = Keyword.fetch!(opts, :compiled_config_description)
    content_hash_description = Keyword.fetch!(opts, :content_hash_description)
    source_ids_description = Keyword.fetch!(opts, :source_ids_description)

    quote bind_quoted: [
            compiled_config_description: compiled_config_description,
            content_hash_description: content_hash_description,
            source_ids_description: source_ids_description
          ] do
      attribute :compiled_config, :map do
        allow_nil?(false)
        public?(true)
        default(%{})
        description(compiled_config_description)
      end

      attribute :content_hash, :string do
        allow_nil?(false)
        public?(true)
        description(content_hash_description)
      end

      attribute :source_ids, {:array, :uuid} do
        allow_nil?(false)
        public?(true)
        default([])
        description(source_ids_description)
      end
    end
  end
end
