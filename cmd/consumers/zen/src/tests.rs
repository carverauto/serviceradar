use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn testdata_path(relative: &str) -> PathBuf {
    let runfile_rel = Path::new("cmd/consumers/zen").join(relative);

    let mut check_candidates = |base: &Path| {
        let mut candidates = vec![base.join(&runfile_rel)];

        if let Ok(ws) = env::var("TEST_WORKSPACE") {
            candidates.push(base.join(ws).join(&runfile_rel));
        }

        candidates.push(base.join("__main").join(&runfile_rel));
        candidates.push(base.join("__main__").join(&runfile_rel));

        candidates.retain(|p| p.exists());
        candidates.into_iter().next()
    };

    if let Ok(runfiles_dir) = env::var("RUNFILES_DIR") {
        if let Some(found) = check_candidates(Path::new(&runfiles_dir)) {
            return found;
        }
    }

    if let Ok(test_srcdir) = env::var("TEST_SRCDIR") {
        if let Some(found) = check_candidates(Path::new(&test_srcdir)) {
            return found;
        }
    }

    Path::new(env!("CARGO_MANIFEST_DIR")).join(relative)
}

#[test]
fn test_host_switch_testdata_parses() {
    let path = testdata_path("testdata/host_switch.json");
    let data = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", path.display(), e));
    let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data).unwrap();
    assert!(!parsed.nodes.is_empty());
}
