//! Slideshow progress persistence (`.porter_history`). Unlike
//! nodejs/src/lib/state.ts, which writes this file unconditionally on every
//! save, this is opt-in via `--resume` -- see
//! docs/adr/0004-sender-language-rust.md's Consequences: the air-gapped
//! "no network, no cloud" premise extends to "no default disk trace" too.
//! Without `--resume`, save/load are no-ops; nothing is ever read or
//! written.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

const HIST_FILE: &str = ".porter_history";

pub fn save_progress(enabled: bool, file_key: &str, index: usize) {
    if !enabled {
        return;
    }
    let mut hist: HashMap<String, usize> = load_raw();
    hist.insert(file_key.to_string(), index);
    if let Ok(json) = serde_json::to_string(&hist) {
        let _ = fs::write(HIST_FILE, json);
    }
}

pub fn load_progress(enabled: bool, file_key: &str) -> usize {
    if !enabled {
        return 0;
    }
    load_raw().get(file_key).copied().unwrap_or(0)
}

fn load_raw() -> HashMap<String, usize> {
    if !Path::new(HIST_FILE).exists() {
        return HashMap::new();
    }
    fs::read_to_string(HIST_FILE)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_is_a_pure_no_op() {
        // Doesn't touch the filesystem at all when disabled -- load returns
        // the default regardless of any on-disk state.
        assert_eq!(load_progress(false, "some-file"), 0);
        save_progress(false, "some-file", 42);
        assert_eq!(load_progress(false, "some-file"), 0);
    }
}
