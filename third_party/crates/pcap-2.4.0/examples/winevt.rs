// On Windows pcap libraries support returning an internal event semaphore handle that can be used wake a blocking call that is waiting for an incoming packet.
// This example illustrates how to use this mechanism.
//
// Run with the a capture device as first parameter:
// > cargo run --example winevt -- "\Device\NPF_{D1DCC24C-C89C-45CF-8E62-0D9268331469}"

#[cfg(windows)]
mod windowsonly {
    use bitflags::bitflags;
    use std::{
        sync::{
            atomic::{AtomicU32, Ordering},
            Arc,
        },
        thread::{sleep, spawn, JoinHandle},
        time::Duration,
    };
    use windows_sys::Win32::{Foundation::HANDLE, System::Threading::SetEvent};

    bitflags! {
      pub(crate) struct CmdFlags: u32 {
        const KILL       = 0b00000001;
        const SHOW_STATS = 0b00000010;

        const ALL = {
          Self::KILL.bits() | Self::SHOW_STATS.bits()
        };
      }
    }

    /// Control structure used to signal requests to capture thread.
    struct Controller {
        jh: Option<JoinHandle<()>>,

        cmdreq: Arc<AtomicU32>,

        /// Windows Event handle used to wake up the to pcap
        hev_wakeup: HANDLE,
    }

    impl Controller {
        /// Tell capture loop thread to terminate.
        ///
        /// Returns once the capture thread is joined.
        fn kill(mut self) {
            // Set kill command bit
            self.cmdreq
                .fetch_or(CmdFlags::KILL.bits(), Ordering::SeqCst);
            unsafe {
                // Wake up the (potentially) blocking catpure call
                if SetEvent(self.hev_wakeup) == 0 {
                    panic!("Unable to signal event");
                }
            }

            if let Some(jh) = self.jh.take() {
                let _ = jh.join();
            }
        }

        fn show_stats(&self) {
            // Set "show stats" command bit
            self.cmdreq
                .fetch_or(CmdFlags::SHOW_STATS.bits(), Ordering::SeqCst);
            unsafe {
                // Wake up the (potentially) blocking catpure call
                if SetEvent(self.hev_wakeup) == 0 {
                    panic!("Unable to signal event");
                }
            }
        }
    }

    /// Run capture loop.  Returns a [`Controller]` that can be used to signal command requests to
    /// the capture loop.
    fn run_cap_loop(devname: &str) -> Controller {
        let cap = pcap::Capture::from_device(devname).unwrap();
        let mut cap = cap.open().unwrap();

        // Ask pcap for a handle to its internal "wake-up" event semaphore
        let hev_wakeup = unsafe { cap.get_event() };

        let cmdreq = AtomicU32::new(0);
        let cmdreq = Arc::new(cmdreq);

        let mut ctrl = Controller {
            jh: None,
            cmdreq: cmdreq.clone(),
            hev_wakeup,
        };
        let jh = spawn(move || {
            let mut pkt_count: u64 = 0;
            let mut pkt_size: u64 = 0;
            loop {
                let res = cap.next_packet();
                let cmd = cmdreq.fetch_and(0, Ordering::SeqCst);

                if cmd & CmdFlags::KILL.bits() != 0 {
                    // Controller requested termination
                    break;
                }
                if cmd & CmdFlags::SHOW_STATS.bits() != 0 {
                    // Controller requested that we show some stats
                    println!("packet count: {pkt_count}");
                    println!("total packet size: {pkt_size}");
                }

                match res {
                    Ok(pkt) => {
                        println!("Got a packet!");
                        pkt_count += 1;
                        pkt_size += pkt.len() as u64;
                    }
                    Err(pcap::Error::TimeoutExpired) => {
                        continue;
                    }
                    Err(e) => {
                        eprintln!("{e}");
                        break;
                    }
                }
            }
        });
        ctrl.jh = Some(jh);

        ctrl
    }

    pub fn main() {
        let args: Vec<String> = std::env::args().skip(1).collect();

        let ctrl = run_cap_loop(&args[0]);

        println!("Waiting 1 second ..");
        sleep(Duration::from_secs(1));

        println!("Tell capture thread to show stats ..");
        ctrl.show_stats();

        println!("Waiting 1 second ..");
        sleep(Duration::from_secs(1));

        println!("Tell capture thread to show stats ..");
        ctrl.show_stats();

        println!("Waiting 1 second ..");
        sleep(Duration::from_secs(1));

        println!("Tell capture thread to terminate ..");
        ctrl.kill();

        println!("Done -- bye");
    }
}

fn main() {
    #[cfg(windows)]
    windowsonly::main();

    #[cfg(not(windows))]
    println!("winevt example is for Windows platforms only");
}
