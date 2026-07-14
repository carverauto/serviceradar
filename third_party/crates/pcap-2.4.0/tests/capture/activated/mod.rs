mod offline;

use tempfile::TempDir;

use pcap::{Capture, Linktype};

use crate::{capture_from_test_file, Packets};

#[test]
fn read_packet_with_full_data() {
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    assert_eq!(capture.next_packet().unwrap().len(), 98);
}

#[test]
fn read_packet_with_truncated_data() {
    let mut capture = capture_from_test_file("packet_snaplen_20.pcap");
    assert_eq!(capture.next_packet().unwrap().len(), 20);
}

#[test]
fn capture_dead_savefile() {
    let mut packets = Packets::new();
    packets.push(1460408319, 1234, 1, 1, &[1]);
    packets.push(1460408320, 4321, 1, 1, &[2]);

    let dir = TempDir::new().unwrap();
    let tmpfile = dir.path().join("test.pcap");

    let cap = Capture::dead(Linktype(1)).unwrap();
    let mut save = cap.savefile(&tmpfile).unwrap();
    packets.foreach(|p| save.write(p));
    drop(save);

    let mut cap = Capture::from_file(&tmpfile).unwrap();
    packets.verify(&mut cap);
}

#[test]
#[cfg(libpcap_1_7_2)]
fn capture_dead_savefile_append() {
    let mut packets1 = Packets::new();
    packets1.push(1460408319, 1234, 1, 1, &[1]);
    packets1.push(1460408320, 4321, 1, 1, &[2]);
    let mut packets2 = Packets::new();
    packets2.push(1460408321, 2345, 1, 1, &[3]);
    packets2.push(1460408322, 5432, 1, 1, &[4]);
    let packets = &packets1 + &packets2;

    let dir = TempDir::new().unwrap();
    let tmpfile = dir.path().join("test.pcap");

    let cap = Capture::dead(Linktype(1)).unwrap();
    let mut save = cap.savefile(&tmpfile).unwrap();
    packets1.foreach(|p| save.write(p));
    drop(save);

    let cap = Capture::dead(Linktype(1)).unwrap();
    let mut save = cap.savefile_append(&tmpfile).unwrap();
    packets2.foreach(|p| save.write(p));
    drop(save);

    let mut cap = Capture::from_file(&tmpfile).unwrap();
    packets.verify(&mut cap);
}

#[test]
fn test_linktype() {
    let capture = capture_from_test_file("packet_snaplen_65535.pcap");
    let linktype = capture.get_datalink();

    assert!(linktype.get_name().is_ok());
    assert_eq!(linktype.get_name().unwrap(), String::from("EN10MB"));
    assert!(linktype.get_description().is_ok());
}

#[test]
fn test_error() {
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    // Trying to get stats from offline capture should error.
    assert!(capture.stats().err().is_some());
}

#[test]
fn test_compile() {
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    let packet = capture.next_packet().unwrap();

    let bpf_capture = Capture::dead(Linktype::ETHERNET).unwrap();

    let program = bpf_capture.compile("dst host 8.8.8.8", false).unwrap();
    let instructions = program.get_instructions();

    assert!(!instructions.is_empty());
    assert!(program.filter(packet.data));

    let program = bpf_capture.compile("src host 8.8.8.8", false).unwrap();
    let instructions = program.get_instructions();

    assert!(!instructions.is_empty());
    assert!(!program.filter(packet.data));
}

#[test]
fn test_compile_optimized() {
    let bpf_capture = Capture::dead(Linktype::ETHERNET).unwrap();

    let program_str = "ip and ip and tcp";
    let program_unopt = bpf_capture.compile(program_str, false).unwrap();
    let instr_unopt = program_unopt.get_instructions();

    let program_opt = bpf_capture.compile(program_str, true).unwrap();
    let instr_opt = program_opt.get_instructions();

    assert!(instr_opt.len() < instr_unopt.len());
}

#[test]
fn test_compile_error() {
    let bpf_capture = Capture::dead(Linktype::ETHERNET).unwrap();

    let program_str = "this is a terrible program";

    let result = bpf_capture.compile(program_str, false);
    assert!(result.is_err());

    let result = bpf_capture.compile(program_str, true);
    assert!(result.is_err());
}

#[test]
fn test_filter() {
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    capture.filter("dst host 8.8.8.8", false).unwrap();

    let result = capture.next_packet();
    assert!(result.is_ok());
}

#[test]
fn read_packet_via_pcap_loop() {
    let mut packets = 0;
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    capture
        .for_each(None, |_| {
            packets += 1;
        })
        .unwrap();
    assert_eq!(packets, 1);
}

#[test]
#[should_panic]
fn panic_in_pcap_loop() {
    let mut capture = capture_from_test_file("packet_snaplen_65535.pcap");
    capture.for_each(None, |_| panic!()).unwrap();
}
