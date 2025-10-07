load("@obazl_tools_cc//config:BASE.bzl",
     _BASE_COPTS    = "BASE_COPTS",
     _define_module_version = "define_module_version")

define_module_version = _define_module_version

BASE_COPTS         = _BASE_COPTS
BASE_LINKOPTS      = []
PROFILE            = ["PROFILE_$(COMPILATION_MODE)"]
