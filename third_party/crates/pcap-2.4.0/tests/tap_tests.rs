/***
* These tests need to be run as root and currently only work on Linux (and maybe MacOs?)
*
* To build and run these tests, run:
*

 cargo test --no-run --test tap_tests |& \
           sed -e 's/[()]//g' | \
           awk '/Executable/ {print $3" --include-ignored"}' | \
           xargs sudo

* which does the build as a non-priv user, extracts the exec binary location of
* the test from 'cargo test', and runs only that as root.
*
* To develop on these tests, you need to manually enable this feature in VSCode ala:
*
*  In VS Code, open the Extensions sidebar, click the gear icon next
*  to the rust-analyzer extension, and choose “Extension Settings.”
*  You can choose whether to customize settings for all projects (the
*  “User” tab) or just the current one (the “Workspace” tab). The
*  setting is labeled “Cargo: Features.”
*
* [from https://users.rust-lang.org/t/passing-feature-flags-to-rust-analyzer/45918/3]
*
* to debug, run:
*
* sudo rust-gdb ./target/debug/deps/tap_test-${BUILD}
*  break tap_test::tests::<TAB>   # to get a list of useful breakpoints
*
* NOTE: tests in rust capture stdio/stderr by default; add "-- --nocapture", e.g.,
*  'cargo test -- --nocapture'
*/
#[cfg(not(windows))]
mod tests {

    use etherparse::{PacketBuilder, PacketHeaders};
    use pcap::Capture;
    use tun_tap::Iface;

    /***
     * Create a Tap interface and make sure that the sendpacket() and next_packet()
     * work as expected
     */
    #[test]
    #[ignore]
    fn conntrack_tap_basic() {
        let (cap, iface) = capture_tap_interface();

        // NOTE: on Linux, if you don't specify a timeout(), it will never return
        let mut cap = cap.snaplen(32000).timeout(500).open().unwrap();

        // create a test packet
        let builder1 = PacketBuilder::ethernet2([1, 1, 1, 1, 1, 1], [2, 2, 2, 2, 2, 2])
            .ipv4([1, 2, 3, 4], [5, 6, 7, 8], 128)
            .tcp(80, 12345, 1, 32000);
        let payload1 = [1, 2, 3, 4, 5, 6, 7, 8];
        let mut pkt1 = Vec::with_capacity(builder1.size(payload1.len()));
        builder1.write(&mut pkt1, &payload1).unwrap();

        // send it in the interface
        let send_len = iface.send(&pkt1).unwrap();
        assert_eq!(send_len, pkt1.len());

        // try to pcap capture it
        let test_pkt1 = cap.next_packet().unwrap();
        // did we capture the whole packet?
        assert_eq!(pkt1.len(), test_pkt1.header.caplen as usize);
        // does it match what we expect?
        assert_eq!(&pkt1, test_pkt1.data);

        // now, try to pcap send it back out that interface
        cap.sendpacket(pkt1.clone()).unwrap();

        let mut buf = vec![0; pkt1.len() * 2];
        let recv_len = iface.recv(&mut buf).unwrap();

        let (test_sendpkt, _) = buf.split_at(recv_len);
        if recv_len != pkt1.len() {
            // wtf!?
            let weird = PacketHeaders::from_ethernet_slice(test_sendpkt).unwrap();
            panic!("weird packet !! {weird:#?}");
        }
        assert_eq!(pkt1.len(), recv_len);
        assert_eq!(pkt1, test_sendpkt);
    }

    /**
     * Bind a tap interface and attach a pcap capture to it and return both
     *
     * Return as a Capture<Inactive> in case the caller wants to set some
     * different options before opening it (maybe?)
     */
    fn capture_tap_interface() -> (Capture<pcap::Inactive>, Iface) {
        use tun_tap::Mode;

        // without_packet_info sets ioctl(fd, IFF_NO_PI ) on the tap fd
        // as described in https://www.gabriel.urdhr.fr/2021/05/08/tuntap/#packet-information
        // it's not useful for l2 tap packets, so wouldl like to skip to simplify tests
        let iface_result = Iface::without_packet_info("testtap%d", Mode::Tap);
        // I know this could/should be a match(), but I think this is cleaner...
        if let Err(e) = iface_result {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                println!("Permission denied - needs tp be run as root/sudo!");
                panic!("Failed to bind the tap interface: PermissionDenied - please run with root/sudo!");
            }
            // common error is to not run these tests as root; provide a nicer message
            panic!("Failed to bind the tap interface: {e:#?}");
        }
        let iface = iface_result.unwrap();
        if cfg!(target_os = "linux") {
            // If IPv6 is enabled, it will broadcast all sorts of stuff on this interface
            // these broadcasts will periodically (heisenbug!) break tests that aren't smart enough
            // so disable IPv6 on the test interface before we start any captures
            // It's important to do this BEFORE bringing up the interface else there's still
            // a race condition (that we were losing more often than not!)
            safe_run_command(format!(
                "sysctl -w net.ipv6.conf.{}.disable_ipv6=1",
                iface.name()
            ));

            // Under Linux, the interface is created, but defaults to 'down' state, where pcap needs it 'up'
            // Yes, it's a hack to use the command line instead of an API, but the netdev APIs are messy
            // TODO: decide if we should move to the https://crates.io/keywords/netlink crate
            safe_run_command(format!("ip link set dev {} up", iface.name()));
        }
        let device = pcap::Device::from(iface.name());
        (Capture::from_device(device).unwrap(), iface)
    }

    /**
     * Run a command on the shell, check the output, and pretty print a panic message and the
     * stderr if it fails.
     */
    fn safe_run_command(cmd: String) {
        use std::process::Command;

        let mut split_cmd = cmd.split_ascii_whitespace();
        // the first token is the program and the rest are args()
        let output = Command::new(split_cmd.next().unwrap())
            .args(split_cmd.collect::<Vec<&str>>())
            .output()
            .unwrap();
        if !output.status.success() {
            panic!(
                "safe_run_command FAILED: '{}' command returned stderr '{:#?}'",
                cmd,
                String::from_utf8(output.stderr)
            );
        }
    }
}
