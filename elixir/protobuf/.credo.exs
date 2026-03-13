{build_config, _binding} = Code.eval_file(Path.expand("../.credo.base.exs", __DIR__))

build_config.(
  included: ["bench/", "conformance/", "lib/", "priv/templates/", "src/", "test/"],
  excluded: [~r"/generated/", ~r"/lib/google/protobuf/"]
)
