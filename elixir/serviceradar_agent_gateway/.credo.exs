{build_config, _binding} = Code.eval_file(Path.expand("../.credo.base.exs", __DIR__))

build_config.(
  included: ["config/", "lib/", "test/"]
)
