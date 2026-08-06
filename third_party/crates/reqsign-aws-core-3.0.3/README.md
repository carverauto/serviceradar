# reqsign-aws-core

Shared AWS credential and request canonicalization foundation for `reqsign`
signing implementations.

This crate contains the AWS credential type, algorithm-independent credential
providers, and canonical request primitives shared by SigV4 and SigV4a. Most
users should depend on `reqsign-aws-v4` or `reqsign-aws-v4a`, which re-export
the relevant public types.
