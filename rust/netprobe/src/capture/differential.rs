//! Task 1.11: our filter compiler must agree with libpcap, packet by packet.
//!
//! This is the only test that can catch a compiler which is confidently wrong.
//! Every other test in [`super::filter`] checks our output against our own
//! understanding of tcpdump; this one checks it against tcpdump.
//!
//! **The property under test is semantic, not syntactic:** for every packet in
//! [`super::corpus`], our program and libpcap's program for the same
//! expression agree on accept versus reject. Asserting bytecode equality would
//! be the wrong test — it turns red on a different libpcap version for filters
//! that are perfectly correct, and it would still miss a program that matches
//! libpcap's shape while differing in an unexercised branch.
//!
//! The libpcap side is a committed fixture
//! (`testdata/libpcap_reference_programs.tsv`) rather than a call to tcpdump.
//! A test that shells out to a host binary goes green by silently skipping
//! when the binary is absent, which on an RBE executor is always.

use std::collections::BTreeMap;

use super::{
    bpf::{Instruction, MAX_SNAPLEN, Program},
    corpus,
    filter::compile,
    interp::{Packet, run},
};

/// The reference programs, parsed from the committed fixture.
///
/// Declared with `include_str!` rather than read at runtime so the fixture is
/// a compile-time dependency: a missing or moved file fails the build instead
/// of making the test skip.
const REFERENCE: &str = include_str!("../../testdata/libpcap_reference_programs.tsv");

fn reference_programs() -> BTreeMap<String, Vec<Instruction>> {
    let mut out = BTreeMap::new();
    for line in REFERENCE.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let (expr, body) = line.split_once('\t').expect("fixture line needs a tab");
        let insns = body
            .split_whitespace()
            .map(|tuple| {
                let f: Vec<u32> = tuple
                    .split(',')
                    .map(|v| v.parse().expect("numeric field"))
                    .collect();
                assert_eq!(f.len(), 4, "each instruction has four fields");
                Instruction::new(f[0] as u16, f[1] as u8, f[2] as u8, f[3])
            })
            .collect();
        out.insert(expr.to_string(), insns);
    }
    out
}

fn accepts(program: &[Instruction], packet: &Packet) -> bool {
    match run(program, packet) {
        Ok(n) => n > 0,
        Err(e) => panic!("interpreter error: {e:?}"),
    }
}

fn ours(expr: &str) -> Program {
    compile(expr, MAX_SNAPLEN).unwrap_or_else(|e| panic!("compile {expr:?}: {e}"))
}

#[test]
fn fixture_is_present_and_plausible() {
    // Guards the whole test: an empty or malformed fixture would make every
    // comparison below vacuously pass.
    let reference = reference_programs();
    assert!(
        reference.len() >= 15,
        "expected the full reference set, got {}",
        reference.len()
    );
    for (expr, program) in &reference {
        assert!(!program.is_empty(), "{expr} has no instructions");
        assert!(
            program.iter().any(|i| i.code == 0x06 && i.k > 0),
            "{expr} never accepts anything, so comparing against it proves nothing"
        );
    }
}

#[test]
fn our_compiler_agrees_with_libpcap_on_every_corpus_packet() {
    let reference = reference_programs();
    let packets = corpus::all();
    let mut compared = 0usize;
    let mut disagreements = Vec::new();

    for (expr, theirs) in &reference {
        let mine = ours(expr);
        for (name, packet) in &packets {
            let mine_accepts = accepts(mine.instructions(), packet);
            let theirs_accepts = accepts(theirs, packet);
            compared += 1;
            if mine_accepts != theirs_accepts {
                disagreements.push(format!(
                    "  {expr:32} on {name:38} ours={mine_accepts:5} libpcap={theirs_accepts}"
                ));
            }
        }
    }

    assert!(
        disagreements.is_empty(),
        "{} of {compared} comparisons disagree with libpcap:\n{}",
        disagreements.len(),
        disagreements.join("\n")
    );

    // Three assertions, because they catch different things and none alone is
    // enough.
    //
    // The first says the loop did what it looks like it does. It CANNOT catch a
    // shrinking input -- it is derived from the same two lengths -- but it does
    // catch a `continue` or an early `break` slipping into the loop, which the
    // old floor could not tell apart from a smaller corpus.
    assert_eq!(
        compared,
        reference.len() * packets.len(),
        "every reference expression must be compared against every corpus packet"
    );

    // The other two catch an input narrowing, and that has to be stated against
    // each input separately. Replacing `compared >= 250` with the product ALONE
    // would have been a regression: 250 was a real floor and did fail when
    // either side shrank far enough. Its weakness was conflating the two --
    // half the corpus with twice the expressions slipped through, and a failure
    // named neither side.
    assert!(
        reference.len() >= 20,
        "the reference set shrank to {} expressions; agreement with libpcap over          a handful of filters proves little",
        reference.len()
    );
    assert!(
        packets.len() >= 15,
        "the corpus shrank to {} packets; a comparison over a handful of frames \
         proves little about two compilers agreeing",
        packets.len()
    );
}

/// The corpus is only useful if it actually distinguishes filters. A corpus
/// every filter accepts, or rejects, would make the comparison above pass no
/// matter how wrong either compiler was.
#[test]
fn corpus_discriminates_rather_than_agreeing_vacuously() {
    let reference = reference_programs();
    let packets = corpus::all();

    for (expr, theirs) in &reference {
        // `not icmp` accepts nearly everything and `icmp` almost nothing;
        // what matters is that no filter is constant across the corpus for
        // BOTH implementations, since that is the shape that proves nothing.
        let accepted = packets.iter().filter(|(_, p)| accepts(theirs, p)).count();
        assert!(
            accepted > 0,
            "{expr} accepts nothing in the corpus, so agreement on it is vacuous"
        );
        assert!(
            accepted < packets.len(),
            "{expr} accepts everything in the corpus, so agreement on it is vacuous"
        );
    }
}

/// The two traps this compiler was written to avoid, asserted directly against
/// libpcap rather than against our own expectations.
#[test]
fn the_fragment_guard_is_actually_exercised() {
    let reference = reference_programs();
    let theirs = &reference["tcp port 443"];
    let mine = ours("tcp port 443");

    let later_fragment = corpus::ipv4_fragment_payload_looks_like_port();
    // libpcap rejects a non-first fragment even though its payload bytes read
    // as port 443. A compiler missing the guard accepts it.
    assert!(
        !accepts(theirs, &later_fragment),
        "libpcap should reject a non-first fragment"
    );
    assert!(
        !accepts(mine.instructions(), &later_fragment),
        "our filter WIDENED to a non-first fragment: the 0x1fff guard is missing or wrong"
    );

    // ...and the first fragment, which does carry ports, is still matched.
    let first_fragment = corpus::ipv4_first_fragment_tcp_443();
    assert_eq!(
        accepts(mine.instructions(), &first_fragment),
        accepts(theirs, &first_fragment),
        "first fragment handling diverges from libpcap"
    );
}

#[test]
fn ip_options_are_actually_exercised() {
    let reference = reference_programs();
    let theirs = &reference["tcp port 443"];
    let mine = ours("tcp port 443");

    let with_options = corpus::ipv4_with_options_tcp_443();
    assert!(
        accepts(theirs, &with_options),
        "libpcap should match a packet with IP options"
    );
    assert!(
        accepts(mine.instructions(), &with_options),
        "our filter NARROWED past a packet with IP options: BPF_MSH is missing or wrong"
    );
}

#[test]
fn arp_addresses_are_actually_exercised() {
    let reference = reference_programs();
    let theirs = &reference["host 192.0.2.1"];
    let mine = ours("host 192.0.2.1");

    let arp = corpus::arp_request_in_test_net();
    assert!(
        accepts(theirs, &arp),
        "libpcap `host` matches ARP sender/target addresses"
    );
    assert!(
        accepts(mine.instructions(), &arp),
        "our `host` missed an ARP packet inside the tested address"
    );

    let rarp = corpus::rarp_in_test_net();
    assert_eq!(
        accepts(mine.instructions(), &rarp),
        accepts(theirs, &rarp),
        "RARP handling diverges from libpcap"
    );
}

#[test]
fn direction_is_actually_exercised() {
    let reference = reference_programs();
    for expr in ["inbound", "outbound"] {
        let theirs = &reference[expr];
        let mine = ours(expr);
        for name in ["ipv4_tcp_443", "ipv4_tcp_443_outbound"] {
            let packet = corpus::all()
                .into_iter()
                .find(|(n, _)| *n == name)
                .map(|(_, p)| p)
                .expect("corpus packet");
            assert_eq!(
                accepts(mine.instructions(), &packet),
                accepts(theirs, &packet),
                "{expr} diverges on {name}"
            );
        }
    }
}
