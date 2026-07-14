extern crate futures;
extern crate inotify;
extern crate tempdir;


use std::{
    fs::File,
    io,
    thread,
    time::Duration,
};

use futures::Stream;
use inotify::{
    Inotify,
    WatchMask,
};
use tempdir::TempDir;


fn main() -> Result<(), io::Error> {
    let mut inotify = Inotify::init()
        .expect("Failed to initialize inotify");

    let dir = TempDir::new("inotify-rs-test")?;

    inotify.add_watch(dir.path(), WatchMask::CREATE | WatchMask::MODIFY)?;

    thread::spawn::<_, Result<(), io::Error>>(move || {
        loop {
            File::create(dir.path().join("file"))?;
            thread::sleep(Duration::from_millis(500));
        }
    });

    let mut buffer = [0; 32];
    let stream = inotify.event_stream(&mut buffer);

    for event in stream.wait() {
        print!("event: {:?}\n", event);
    }

    Ok(())
}
