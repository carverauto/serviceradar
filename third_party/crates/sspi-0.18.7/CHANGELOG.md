# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [[0.18.7](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.6...sspi-v0.18.7)] - 2026-01-16

### <!-- 1 -->Features

- NT Hash Authentication ([#585](https://github.com/Devolutions/sspi-rs/issues/585)) ([21b45e16dc](https://github.com/Devolutions/sspi-rs/commit/21b45e16dcee7171cd9ae70df37cee8cdf41df0e)) 

  Adds support for NT hash (pass-the-hash) authentication,
  allowing authentication using pre-computed NT hashes instead of
  plaintext passwords.

## [[0.18.6](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.5...sspi-v0.18.6)] - 2026-01-05

### <!-- 4 -->Bug Fixes

- Accept variable-length MsvAvSingleHost AvPair ([#580](https://github.com/Devolutions/sspi-rs/issues/580)) ([28f8d74b8c](https://github.com/Devolutions/sspi-rs/commit/28f8d74b8c4f982e047f0bc7738498ac217f6553)) 

  Windows 11 Build 26200+ sends an 80-byte MsvAvSingleHost structure
  instead of the traditional 48 bytes. Per MS-NLMP specification, fields
  after MachineID MUST be ignored on receipt.
  
  This change:
  - Changes SingleHost from fixed [u8; 48] to Vec<u8>
  - Relaxes validation from == 48 to >= 48 bytes
  - Preserves full data for round-trip serialization
  
  Fixes RDP credential injection failures when clients use Windows 11
  Build 26200 or later.

## [[0.18.5](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.4...sspi-v0.18.5)] - 2025-12-11

### <!-- 4 -->Bug Fixes

- Don't use eprintln on unknown packages ([#558](https://github.com/Devolutions/sspi-rs/issues/558)) ([df6181291c](https://github.com/Devolutions/sspi-rs/commit/df6181291ccf6f9fb2a0a59151b43676663b2d74)) 

- Use `String::from_utf16_lossy` over `String::from_utf16` to avoid changing the meaning of some buffers in case of invalid UTF-16 input ([#568](https://github.com/Devolutions/sspi-rs/issues/568)) ([a4889f5b1e](https://github.com/Devolutions/sspi-rs/commit/a4889f5b1e802395b09954f5846d1a6433546281)) 

### <!-- 7 -->Build

- Update dependencies

## [[0.18.4](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.3...sspi-v0.18.4)] - 2025-11-18

### <!-- 7 -->Build

- Exclude cryptoki for WASM ([#545](https://github.com/Devolutions/sspi-rs/issues/545)) ([9e4a84a9ee](https://github.com/Devolutions/sspi-rs/commit/9e4a84a9ee07c81da07e799e3e209094c9045c83)) 

  This fixes builds for the wasm32 target.

## [[0.18.3](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.2...sspi-v0.18.3)] - 2025-11-07

### <!-- 1 -->Features

- Add `NT_ENTERPRISE` support in server-side Kerberos ([#535](https://github.com/Devolutions/sspi-rs/issues/535)) ([40785e3123](https://github.com/Devolutions/sspi-rs/commit/40785e3123e381180ac9a75e99248a0287fc5d71)) 

  This is needed when want to connect using FQDN instead of down-level logon name.

### <!-- 3 -->Revert

- Implement `Default` for `SmartCardType` ([#534](https://github.com/Devolutions/sspi-rs/issues/534)) ([7280f7a67b](https://github.com/Devolutions/sspi-rs/commit/7280f7a67b100719052ade72333d373bf956541f)) 

  It actually does not make sense to implement Default for SmartCardType.
  A user-provided PIN must be set.
  
  Release 0.18.2 was yanked.

### <!-- 4 -->Bug Fixes

- TLS 1.3 support in TSSSP module ([#536](https://github.com/Devolutions/sspi-rs/issues/536)) ([0605cf01f8](https://github.com/Devolutions/sspi-rs/commit/0605cf01f861aca8191e3134fb885bde5eb50506)) 

  * Adds `CipherSuite::TLS13_AES_256_GCM_SHA384` support.
  * Fixes TLS packet header validation: TLS 1.3 uses TLS 1.2 version in the packet header.

- Pin leftover pre-release crypto crates ([#538](https://github.com/Devolutions/sspi-rs/issues/538)) ([6fc91fa977](https://github.com/Devolutions/sspi-rs/commit/6fc91fa977d217b04cdce23e66d56a8a398988e3)) 

  The patch version upgrade is not allowed to bring breaking changes, but
  this rule doesn't work for an `rc` version. So we should pin the `rc`
  versions, to not allow _cargo_ update to a new `rc` automatically.

## [[0.18.2](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.1...sspi-v0.18.2)] - 2025-11-04 (Yanked)

### <!-- 1 -->Features

- Implement `Default` for `SmartCardType` ([#532](https://github.com/Devolutions/sspi-rs/issues/532)) ([3555b377e8](https://github.com/Devolutions/sspi-rs/commit/3555b377e8aeb5a8c376b2ecec9dcb1a2fd79560)) 

## [[0.18.1](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.18.0...sspi-v0.18.1)] - 2025-10-29

### <!-- 7 -->Build

- Bump hickory-resolver from 0.24.4 to 0.25.2 ([#426](https://github.com/Devolutions/sspi-rs/issues/426)) ([59857e66c2](https://github.com/Devolutions/sspi-rs/commit/59857e66c29e9130af2d24e3c7d79858ce1b55cd)) 

## [[0.18.0](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.17.0...sspi-v0.18.0)] - 2025-10-14

### <!-- 4 -->Bug Fixes

- DH client default parameters: remove leading zero ([#514](https://github.com/Devolutions/sspi-rs/issues/514)) ([8114b570bc](https://github.com/Devolutions/sspi-rs/commit/8114b570bcfa4320b4972c300705a5e93e762965)) 

- [**breaking**] Async network client returns `!Send` future ([#513](https://github.com/Devolutions/sspi-rs/issues/513)) ([218ddf3e79](https://github.com/Devolutions/sspi-rs/commit/218ddf3e792580caf1f094ff197a3790f61248e5)) 

### <!-- 7 -->Build

- Bump picky to the latest version ([#516](https://github.com/Devolutions/sspi-rs/issues/516)) ([972e04b153](https://github.com/Devolutions/sspi-rs/commit/972e04b15393acf2028ae7fde0f55d104e8a9294)) 

- Bump the patch group across 1 directory with 2 updates ([#519](https://github.com/Devolutions/sspi-rs/issues/519)) ([aaa6e78617](https://github.com/Devolutions/sspi-rs/commit/aaa6e78617b17ee0870c3044f2ac6922c6831017)) 

## [[0.17.0](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.16.1...sspi-v0.17.0)] - 2025-10-06

### <!-- 1 -->Features

- Data sigining using scard (#491) ([6728fb525c](https://github.com/Devolutions/sspi-rs/commit/6728fb525cedc96b395eed5dc4a8ea357b036b36)) 

### <!-- 4 -->Bug Fixes

- [**breaking**] Move `cert_utils` from `sspi` crate to `ffi` (#507) ([c9337c8f64](https://github.com/Devolutions/sspi-rs/commit/c9337c8f64a6236396242275847989a35db735ac)) 

- [**breaking**] Fix lifetimes in initialize_security_context_impl (#495) ([370951c1b0](https://github.com/Devolutions/sspi-rs/commit/370951c1b017bfef4276185b374345e8b6b1e532)) 

### <!-- 7 -->Build

- Bump the windows crates

- Bump the crypto dependencies (#489) ([1ecba764ec](https://github.com/Devolutions/sspi-rs/commit/1ecba764ec3b04e147ae76d018414afa8bec5f88)) 

## [[0.16.1](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.16.0...sspi-v0.16.1)] - 2025-08-19

### <!-- 1 -->Features

- Add method to set the channel bindings for a session (#479) ([0c0e225fe7](https://github.com/Devolutions/sspi-rs/commit/0c0e225fe7d7ddffc18ad0176deba207edaf3524)) 

  Setting and sending the CBs is described in Sec. 3.1.5.2.1 of the NTLM spec, admittedly in a slightly confusing way, which may seem to suggest that the bindings are somehow part of the CHALLENGE message, but they are not: knowledge of CBs is strictly local to the client, therefore the client should send them in AUTHENTICATE.

## [[0.16.0](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.14...sspi-v0.16.0)] - 2025-07-07

### <!-- 1 -->Features

- Server-side Kerberos implementation (#440) ([943a297edd](https://github.com/Devolutions/sspi-rs/commit/943a297eddad91bf6dfa02bdb53b422453df0ed9)) 

### <!-- 4 -->Bug Fixes

- Server-side Kerberos fixes (#457) ([27ce28dad5](https://github.com/Devolutions/sspi-rs/commit/27ce28dad5aa490d094b4ea1db5a315ea1478264)) 

- Kerberos server MIC token generation and validation (#464) ([12fbd706a8](https://github.com/Devolutions/sspi-rs/commit/12fbd706a8e807b4e4ea9b6bb39f4bace60afd9a)) 

- Kerberos server WRAP token generation and validation (#463) ([4bbe4071c8](https://github.com/Devolutions/sspi-rs/commit/4bbe4071c80172ee2c85552ef1060a65394a45c0)) 

## [[0.15.14](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.13...sspi-v0.15.14)] - 2025-07-01

### <!-- 7 -->Build

- Update picky-krb to 0.11 (#460) ([5157bee02b](https://github.com/Devolutions/sspi-rs/commit/5157bee02b0383571c726801bda15f0dd9dc7934)) 



## [[0.15.13](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.12...sspi-v0.15.13)] - 2025-06-23

### <!-- 7 -->Build

- Bump windows-sys from 0.59.0 to 0.60.2 in the windows group across 1 directory (#455) ([5744c8b4b3](https://github.com/Devolutions/sspi-rs/commit/5744c8b4b3aa5a47a2a25e9375434333de769002)) 

## [[0.15.12](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.11...sspi-v0.15.12)] - 2025-06-20

### <!-- 4 -->Bug Fixes

- Invalid Kerberos token DER encoding (#453) ([0ec3e687dd](https://github.com/Devolutions/sspi-rs/commit/0ec3e687dd28ff95910c79b4781d538cbffb9a80)) 

  The default behavior of serializing a KrbMessage<T> was accidentally changed.

## [[0.15.11](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.10...sspi-v0.15.11)] - 2025-06-11

### <!-- 4 -->Bug Fixes

- Negotiate attempts KDC detection even when Kerberos is disabled (#447) ([c56132c3f8](https://github.com/Devolutions/sspi-rs/commit/c56132c3f8d3b7e957e64577109158511ee3f4b8)) 

## [[0.15.10](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.9...sspi-v0.15.10)] - 2025-06-10

### <!-- 7 -->Build

- Update picky-krb to 0.10 (#448) ([b8b983d7ae](https://github.com/Devolutions/sspi-rs/commit/b8b983d7aecb8e1c84037d157c2b932668e069b1)) 

## [[0.15.9](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.8...sspi-v0.15.9)] - 2025-06-05

### <!-- 7 -->Build

- Bump windows-registry from 0.4.0 to 0.5.2 in the windows group across 1 directory (#444) ([9a349f7bdc](https://github.com/Devolutions/sspi-rs/commit/9a349f7bdcfe33658af27420af3dd38a88d773ab)) 

## [[0.15.8](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.7...sspi-v0.15.8)] - 2025-06-05

### Build

- Migrate from `winreg` to `windows-registry` crate (#441) ([8631235c8a](https://github.com/Devolutions/sspi-rs/commit/8631235c8a3f93e6f4573142101a25210adb49a5)) 



## [[0.15.7](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.6...sspi-v0.15.7)] - 2025-05-29

### <!-- 4 -->Bug Fixes

- Do not log at info-level return values (#438) ([68d02e410d](https://github.com/Devolutions/sspi-rs/commit/68d02e410dadf0278ed2a109117c71c43920ea4f)) 

## [[0.15.6](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.5...sspi-v0.15.6)] - 2025-05-27

### <!-- 4 -->Bug Fixes

- Lower info-level logs to debug-level (#436) ([665cb1e1dc](https://github.com/Devolutions/sspi-rs/commit/665cb1e1dc148683779e65f66d1408ddaa911bea)) 

## [[0.15.5](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.4...sspi-v0.15.5)] - 2025-04-25

### <!-- 1 -->Features

- Add `query_context_session_key` (#417) ([862657a57c](https://github.com/Devolutions/sspi-rs/commit/862657a57c781e348ef5ccafe540511b19148b44)) 

  This addition is an implementation for the SSP API
  `QueryContextAttributesEx(SECPKG_ATTR_SESSION_KEY)`. It is required for
  protocols such as SMB, and adding it to the `Sspi` trait, enables access
  to it across all the SSP packages implemented.
  
  This adds the option for using Kerberos and Negotiate session keys.

## [[0.15.4](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.3...sspi-v0.15.4)] - 2025-03-24

### <!-- 7 -->Build

- Update dependencies

## [[0.15.3](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.2...sspi-v0.15.3)] - 2025-03-12

### <!-- 4 -->Bug Fixes

- Set correct seq number in MIC token (#390) ([69f03c2933](https://github.com/Devolutions/sspi-rs/commit/69f03c2933c1da106b64a565a757666cd4d94bde)) 

  Fixes Kerberos LDAP auth.
  The problem was in the invalid sequence number in MIC token.

- NTLM RPC auth (#395) ([34d896c9ce](https://github.com/Devolutions/sspi-rs/commit/34d896c9cee7e0b3e0d5ee3c5002c781d9fc8fbf)) 

## [[0.15.2](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.1...sspi-v0.15.2)] - 2025-02-27

### <!-- 1 -->Features

- Support `SECBUFFER_READONLY_WITH_CHECKSUM` flag (#357) ([397fd9502d](https://github.com/Devolutions/sspi-rs/commit/397fd9502dc315e4e8e7c4700b6e789c5e7b44c3)) 

- Add `USE_DCE_STYLE` flag support (#358) ([0f78bccaea](https://github.com/Devolutions/sspi-rs/commit/0f78bccaea7ac5620f83de68d3559f212262c789)) 

### <!-- 4 -->Bug Fixes

- Kerberos authentication and encryption for RPC and RDP (#372) ([442dfc1382](https://github.com/Devolutions/sspi-rs/commit/442dfc1382033f6f81bb4cd021cca7318cce224e)) 

## [[0.15.1](https://github.com/Devolutions/sspi-rs/compare/sspi-v0.15.0...sspi-v0.15.1)] - 2025-02-04

### <!-- 1 -->Features

- Add `make_signature` and `verify_signature` to `Sspi` trait (#343) ([040188a34d](https://github.com/Devolutions/sspi-rs/commit/040188a34d5d7b8607825b25a4eb78c25c6b57cc)) 

### <!-- 4 -->Bug Fixes

- Store session key when using server-side NTLM implementation (#354) ([41d1ca7fed](https://github.com/Devolutions/sspi-rs/commit/41d1ca7fed623759dcc9ff6f28c7558ecfa6fcbd)) 
