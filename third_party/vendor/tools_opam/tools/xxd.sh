#!/bin/sh

set -x

cd lib/templates;
find ocamlsdk -name "*.BUILD" -depth 1 -exec xxd -i {} {}.c \;
find compiler_libs -name "*.BUILD" -depth 1 -exec xxd -i {} {}.c \;
find toolchain -name "*.BUILD" -depth 1 -exec xxd -i {} {}.c \;
