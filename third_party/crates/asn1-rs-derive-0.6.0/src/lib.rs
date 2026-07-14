mod alias;
mod container;
mod sequence;
mod set;
mod tostatic;
use alias::*;
use sequence::*;
use set::*;
use tostatic::derive_tostatic;

synstructure::decl_derive!([BerAlias, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_ber_alias);
synstructure::decl_derive!([DerAlias, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_der_alias);

synstructure::decl_derive!([BerSequence, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_ber_sequence);
synstructure::decl_derive!([DerSequence, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_der_sequence);

synstructure::decl_derive!([BerSet, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_ber_set);
synstructure::decl_derive!([DerSet, attributes(
    debug_derive,
    default,
    optional,
    tag_explicit,
    tag_implicit,
    error,
    map_err
)] => derive_der_set);

synstructure::decl_derive!([ToStatic, attributes(
    debug_derive
)] => derive_tostatic);

synstructure::decl_derive!([ToDerSequence, attributes(
    debug_derive,
)] => derive_toder_sequence);
