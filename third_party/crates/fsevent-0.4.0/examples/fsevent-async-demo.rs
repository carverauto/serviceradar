extern crate fsevent;

use std::sync::mpsc::channel;
use std::thread;

fn main() {
    let (sender, receiver) = channel();

    let _t = thread::spawn(move || {
        let fsevent = fsevent::FsEvent::new(vec![".".to_string()]);
        let handle = fsevent.observe_async(sender).unwrap();
        std::thread::sleep(std::time::Duration::from_secs(5)); // sleep five seconds
        fsevent.shutdown_observe(handle);
    });

    loop {
        let duration = std::time::Duration::from_secs(1);
        match receiver.recv_timeout(duration) {
            Ok(val) => println!("{:?}", val),
            Err(e) => match e {
                std::sync::mpsc::RecvTimeoutError::Disconnected => break,
                _ => {} // This is the case where nothing entered the channel buffer (no file mods).
            }
        }
    }
}
