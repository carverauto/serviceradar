extern crate futures;
extern crate inotify;
extern crate tempdir;
extern crate tokio;

use inotify::{Inotify, WatchMask};
use std::{fs::File, io, thread, time::Duration};
use tempdir::TempDir;
use tokio::prelude::*;

fn main() -> Result<(), io::Error> {

    let mut inotify = Inotify::init()?;

    let dir = TempDir::new("inotify-rs-test")?;

    inotify.add_watch(dir.path(), WatchMask::CREATE | WatchMask::MODIFY)?;

    thread::spawn::<_, Result<(), io::Error>>(move || loop {
        File::create(dir.path().join("file"))?;
        thread::sleep(Duration::from_millis(500));
    });

    let future = inotify
        .event_stream([0; 32])
        .map_err(|e| println!("inotify error: {:?}", e))
        .for_each(move |event| {
            println!("event: {:?}", event);
            Ok(())
        });

    tokio::run(future);
    Ok(())
}
