use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, SyncSender};
use std::thread;
use std::time::Duration;

use notify::{DebouncedEvent, RecommendedWatcher, RecursiveMode, Watcher};

use glob::{glob, Pattern};

use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use crate::flowgger::input::file::worker::FileWorker;

pub struct FileDiscovery {
    watcher: RecommendedWatcher,
    event_rx: Receiver<DebouncedEvent>,
    path_match: Pattern,
    log_tx: SyncSender<Vec<u8>>,
    decoder: Box<dyn Decoder + Send>,
    encoder: Box<dyn Encoder + Send>,
}

impl FileDiscovery {
    pub fn new(
        path_match: &str,
        log_tx: SyncSender<Vec<u8>>,
        decoder: Box<dyn Decoder + Send>,
        encoder: Box<dyn Encoder + Send>,
    ) -> FileDiscovery {
        let (tx, rx) = channel();
        let watcher =
            Watcher::new(tx, Duration::from_secs(1)).expect("Cannot initialize fs watcher");

        FileDiscovery {
            watcher,
            event_rx: rx,
            path_match: Pattern::new(path_match).expect("Wrong input.src"),
            log_tx,
            decoder,
            encoder,
        }
    }

    pub fn run(&mut self) {
        let path = self.path_match.clone();
        self.add_initial_watches(PathBuf::from(path.as_str()));
        self.start_initial_workers();

        loop {
            match self.event_rx.recv() {
                Ok(event) => match event {
                    DebouncedEvent::Create(event_path) => {
                        if event_path.metadata().unwrap().is_dir() {
                            if should_be_watched(&self.path_match, &event_path) {
                                self.add_directory_watch(&event_path)
                            }
                        } else if self.path_match.matches_path(&event_path) {
                            self.start_worker(&event_path, false);
                        }
                    }
                    DebouncedEvent::NoticeWrite(event_path) => {
                        if self.path_match.matches_path(&event_path) {
                            self.start_worker(&event_path, false);
                        }
                    }
                    _ => println!("Unknown DebouncedEvent {:?}", event),
                },
                Err(e) => println!("Error receiving event: {}", e),
            }
        }
    }

    fn add_initial_watches(&mut self, path_match: PathBuf) {
        for entry in glob(path_match.to_str().unwrap()).expect("Failed to read glob pattern") {
            match entry {
                Ok(path) => {
                    if path.is_dir() {
                        self.add_directory_watch(&path)
                    }
                }
                Err(e) => panic!("Failed to read glob entry: {}", e),
            }
        }
        if let Some(parent) = path_match.clone().parent() {
            self.add_initial_watches(PathBuf::from(parent))
        }
    }

    fn start_initial_workers(&self) {
        for entry in glob(self.path_match.as_str()).expect("Failed to read glob pattern") {
            match entry {
                Ok(path) => self.start_worker(&path, true),
                Err(e) => panic!("Failed to read glob entry: {}", e),
            };
        }
    }

    fn add_directory_watch(&mut self, path: &Path) {
        self.watcher
            .watch(path, RecursiveMode::NonRecursive)
            .unwrap();
    }

    fn start_worker(&self, path: &Path, from_tail: bool) {
        let p = path.to_owned().clone();
        let t = self.log_tx.clone();
        let d: Box<dyn Decoder + Send> = self.decoder.clone_boxed();
        let e: Box<dyn Encoder + Send> = self.encoder.clone_boxed();
        thread::spawn(move || {
            let mut worker = FileWorker::new(&p, t, d, e);
            worker.run(from_tail);
        });
    }
}

fn should_be_watched(match_path: &Pattern, path: &Path) -> bool {
    if match_path.matches_path(path) {
        true
    } else {
        match PathBuf::from(match_path.as_str()).parent() {
            Some(parent) => {
                should_be_watched(&Pattern::new(parent.to_str().unwrap()).unwrap(), path)
            }
            None => false,
        }
    }
}

#[test]
fn test_should_be_watched() {
    struct TestData {
        match_path: Pattern,
        path: PathBuf,
        result: bool,
    }
    let tt = vec![
        TestData {
            match_path: Pattern::new("/tmp/1.txt").unwrap(),
            path: PathBuf::from("/tmp/1.txt"),
            result: true,
        },
        TestData {
            match_path: Pattern::new("/tmp/1.txt").unwrap(),
            path: PathBuf::from("/tmp/2.txt"),
            result: false,
        },
        TestData {
            match_path: Pattern::new("/tmp/*.txt").unwrap(),
            path: PathBuf::from("/tmp/1.txt"),
            result: true,
        },
        TestData {
            match_path: Pattern::new("/tmp/*.txt").unwrap(),
            path: PathBuf::from("/tmp/2.txt"),
            result: true,
        },
        TestData {
            match_path: Pattern::new("/tmp/1.txt").unwrap(),
            path: PathBuf::from("/tmp"),
            result: true,
        },
        TestData {
            match_path: Pattern::new("/tmp/1.txt").unwrap(),
            path: PathBuf::from("/tmp/logs"),
            result: false,
        },
        TestData {
            match_path: Pattern::new("/tmp/*/1.txt").unwrap(),
            path: PathBuf::from("/tmp/logs/1.txt"),
            result: true,
        },
        TestData {
            match_path: Pattern::new("/tmp/*/1.txt").unwrap(),
            path: PathBuf::from("/tmp/logs/1/1.txt"),
            result: true,
        },
    ];

    for data in tt {
        assert_eq!(data.result, should_be_watched(&data.match_path, &data.path));
    }
}
