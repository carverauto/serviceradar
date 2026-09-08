
# [ADLR]: Multiarch OCI Images
* Date: Aug/18 2026
* Author: Marvin Hansen
* Contact: marvin.hansen@gmail.com

## Abstract

-- Short summary here

## Driving Event

Following the migration to the Hermetic toolchain that simplified cross compilation, it was decided to leverage the cross compilation to finally build multi-arc images for all container images.

## Process

### Assesmemnt 

An initial assessment divided the existing OCI images into three categories: 
1. trivially multi-arch, 
2. minor correction necessary,  
3. major migration required.

### Trivial resolution

The first category usually required a corresponding ARM64 base image and some basal configuration, and then the multi-arc image were completed.

### Resolving minor corrections. 

The second category was dominanted by Elxir because the elixir byte code, similar to the java byte code is actually platform agnostic, but the rules Erlang could not configure the OTP runtime per platform so it always used Intel for everything. Once that was patched, the rest  was straightforward.

The insight about the OTP runtime has then lead to the discovery that the old rules_erlang were compiling the entire OTP runtime for Intel for every single target. That was one of the big reasons the elixir and Erlang build times were so absurd long compared to everything else. I added an option to download a platform specific original OTP binary published by the project itself, hash over the distribution hash, and use this only once instead of 250 recompilations... This has cut the cold rebuild time of the elixir source tree in half, but more importantly the OTP runtime is now a hashed target so it stays in the bazel cache when the code changes instead of frequent rebuilds.

### Major migration 

Only two images landed into the third category:
* webng
* core

### Webng migration

webng had a system dependency on ADBC, whih needed make to build, to ingest arrow data.

However, web_ng has two arrow ingest routes:

GET /v1/stream/:session_id - working via Ash

GET /v1/field-survey/:session_id/{rf-observations,pose-samples,spectrum-observations} via Adbc.Connection.bulk_insert.

The second ednpoint never actually worked because the adbc CNPG driver never shipped in any image. As it turned out, the second endpoint existed because of an unfished Swift client 
that wasnt used and therefore never hit the dead endpoint and
therefore the dead endpoint was not discovered before.

Furthermore, the working edndpoing was using ash to ingest arrow data while the
dead endpoint tried to do the same with ADBC, which didnt even worked.

In response, the issue was resolved by replacing the broken ADBC with the exisit ash library 
so that the dead endpoint started working, the broken ADBC dependency got removed and with
it the need wor work with cmak, which then unblocked the multiarch image build.

That however has as exposed a number of fundamental non hermetic bugs with silent fall through in the mix_app rule.
Technically, web-ng already fully cross compiles after the ADBC removal, its just that the mix_app rule bundling 
mixes up platforms and packages arm and intel stuff together because of those non hermetic bugs.

The whole class of bugs on this migration shared one casuse: an architecture-keyed artefact
fetched over the network from inside a build action, keyed on the machine running the build
instead of the machine the output is for. It appeared in four unrelated packages, through
three different mechanisms (elixir_make, cc_precompiler, rustler_precompiled, Bundlex).

The reason it kept recurring is an asymmetry in mix_app: a package that COMPILES native code
was handed the target through CC/CXX/CFLAGS and got it right, while a package that DOWNLOADS
a prebuilt got no target signal at all and fell back to the executor’s triple. Nothing in
the build could tell the two apart, the first was ever tested, and the failure
surfaced only on an arm64 machine as a misleading ENOENT.

In response, the mix_app rule was rewriten to be hermetic so that it only dependes on declared input.

### Core

Following the mix_app rule rewrite, a multi arch core elix became tractable. 
However, `core-elx` needed three separate fixes:

- **`ex_dtls` / `ex_libsrt`** resolved OpenSSL through pkg-config, which reports only
  `-lssl -lcrypto` and leaves the directories to compiler defaults -- so they were pinned to
  the executor's gcc, which emits amd64 wherever it runs. The answer was a sysroot, not a
  compiler: `//third_party/openssl` builds one per architecture from pinned debs.
- **`ex_libsrt`** is C++, and Bundlex builds its own link line, so the C++ runtime rules_cc
  would have supplied was simply absent. 
- **`vix`** executes its own NIF during `mix compile`, so the compile needs the *executor's*
  architecture while the shipped `priv` needs the *target's*.

The mix_app rule rewrite was a major effort, it took considerable verification effort to ensure all
targets cross compile correctly and all tests pass. However, afterwards, the build seems more robust
and even a handful of lingering issues (local warning) were resolved.


## Lesson(s) Learned




## Recommendation(s)


## Related resources:

* //build/mix_app.bzl -- target triple export, precompiled NIF staging, ELF assertion
* //third_party/patches/bundlex/target_triple.patch -- target-keyed precompiled OS dep URLs
* //third_party/patches/bundlex/local_precompiled.patch -- staged archives over github
* //third_party/precompiled_nifs, //third_party/membrane -- the staged, pinned artefacts
* //docker/images:multiarch_index_test -- per-layer ELF verification of every index
* openspec/changes/move-anomaly-detection-to-edge -- unrelated, but the other consumer of
  the arm64 agent images this migration produces

