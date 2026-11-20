//! Pure-Rust HuggingFace `tokenizer.json` loader and text encoder.
//!
//! Supports Unigram (SentencePiece metaspace `▁` used by SigLIP), BPE, and
//! WordPiece/vocab-map `tokenizer.json` files without pulling native C/C++
//! build-script crates (`onig_sys`, `esaxx-rs`), keeping Bazel RBE hermetic.

use crate::errors::MediaWorkerError;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

const METASPACE: char = '\u{2581}';

#[derive(Debug, Clone)]
enum TokenizerModel {
    Unigram {
        pieces: HashMap<String, (u32, f64)>,
        max_piece_bytes: usize,
        unk_id: u32,
        vocab_size: usize,
    },
    Bpe {
        vocab: HashMap<String, u32>,
        merges: HashMap<(String, String), usize>,
        unk_id: u32,
        end_of_word_suffix: Option<String>,
        vocab_size: usize,
    },
    WordPiece {
        vocab: HashMap<String, u32>,
        continuing_prefix: String,
        unk_id: u32,
        vocab_size: usize,
    },
}

/// Pure-Rust tokenizer loaded from a local HuggingFace `tokenizer.json`.
#[derive(Debug, Clone)]
pub struct PureRustTokenizer {
    model: TokenizerModel,
    lowercase: bool,
    pad_token_id: Option<u32>,
    eos_token_id: Option<u32>,
}

impl PureRustTokenizer {
    /// Loads a tokenizer strictly from a local `tokenizer.json` file.
    pub fn from_file(path: &Path) -> Result<Self, MediaWorkerError> {
        let bytes = std::fs::read(path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading tokenizer file '{}': {err}",
                path.display()
            ))
        })?;
        Self::from_bytes(&bytes)
    }

    /// Parses a HuggingFace `tokenizer.json` document from memory.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, MediaWorkerError> {
        let root: Value = serde_json::from_slice(bytes).map_err(|err| {
            MediaWorkerError::inference_failed(format!("invalid tokenizer.json: {err}"))
        })?;

        let lowercase = detect_lowercase_normalizer(root.get("normalizer"));
        let (added_pad, added_eos, added_unk) =
            parse_added_special_tokens(root.get("added_tokens"));

        let model_val = root.get("model").ok_or_else(|| {
            MediaWorkerError::inference_failed("tokenizer.json missing 'model' object")
        })?;
        let model_type = model_val
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_else(|| {
                if model_val.get("vocab").is_some_and(Value::is_array) {
                    "Unigram"
                } else if model_val.get("merges").is_some() {
                    "BPE"
                } else {
                    "WordPiece"
                }
            });

        let model = match model_type {
            "Unigram" => parse_unigram_model(model_val, added_unk)?,
            "BPE" => parse_bpe_model(model_val, added_unk)?,
            "WordPiece" => parse_wordpiece_model(model_val, added_unk)?,
            other => {
                return Err(MediaWorkerError::inference_failed(format!(
                    "unsupported tokenizer.json model type '{other}'"
                )));
            }
        };

        Ok(Self {
            model,
            lowercase,
            pad_token_id: added_pad,
            eos_token_id: added_eos,
        })
    }

    pub fn vocab_size(&self) -> usize {
        match &self.model {
            TokenizerModel::Unigram { vocab_size, .. }
            | TokenizerModel::Bpe { vocab_size, .. }
            | TokenizerModel::WordPiece { vocab_size, .. } => *vocab_size,
        }
    }

    /// Encodes `text` into raw token IDs without padding or EOS insertion.
    pub fn encode_raw(&self, text: &str) -> Vec<u32> {
        let normalized = normalize_text(text, self.lowercase);
        if normalized.is_empty() {
            return Vec::new();
        }
        match &self.model {
            TokenizerModel::Unigram {
                pieces,
                max_piece_bytes,
                unk_id,
                ..
            } => encode_unigram(&normalized, pieces, *max_piece_bytes, *unk_id),
            TokenizerModel::Bpe {
                vocab,
                merges,
                unk_id,
                end_of_word_suffix,
                ..
            } => encode_bpe(
                &normalized,
                vocab,
                merges,
                *unk_id,
                end_of_word_suffix.as_deref(),
            ),
            TokenizerModel::WordPiece {
                vocab,
                continuing_prefix,
                unk_id,
                ..
            } => encode_wordpiece(&normalized, vocab, continuing_prefix, *unk_id),
        }
    }

    /// Encodes `text` into a fixed-length `[max_len]` token ID vector suitable
    /// for SigLIP text tower input, appending EOS and padding with PAD.
    pub fn encode_padded(
        &self,
        text: &str,
        max_len: usize,
        config_pad_id: u32,
        config_eos_id: u32,
        vocab_limit: usize,
    ) -> Result<Vec<u32>, MediaWorkerError> {
        if max_len == 0 || vocab_limit == 0 {
            return Err(MediaWorkerError::inference_failed(
                "tokenizer max_len and vocab_limit must be > 0",
            ));
        }

        let limit = vocab_limit as u32;
        let pad_id = resolve_valid_special_id(self.pad_token_id, config_pad_id, limit);
        let eos_id = resolve_valid_special_id(self.eos_token_id, config_eos_id, limit);

        let mut ids: Vec<u32> = self
            .encode_raw(text)
            .into_iter()
            .map(|id| if id < limit { id } else { pad_id })
            .collect();

        let content_cap = max_len.saturating_sub(1);
        ids.truncate(content_cap);
        ids.push(eos_id);
        while ids.len() < max_len {
            ids.push(pad_id);
        }
        Ok(ids)
    }
}

fn resolve_valid_special_id(tokenizer_id: Option<u32>, config_id: u32, vocab_limit: u32) -> u32 {
    if config_id < vocab_limit {
        config_id
    } else if let Some(tid) = tokenizer_id
        && tid < vocab_limit
    {
        tid
    } else {
        0
    }
}

fn detect_lowercase_normalizer(val: Option<&Value>) -> bool {
    let Some(v) = val else {
        return true;
    };
    if v.get("lowercase").and_then(Value::as_bool).unwrap_or(false) {
        return true;
    }
    if v.get("type")
        .and_then(Value::as_str)
        .is_some_and(|t| t.eq_ignore_ascii_case("Lowercase"))
    {
        return true;
    }
    if let Some(seq) = v.get("normalizers").and_then(Value::as_array) {
        return seq
            .iter()
            .any(|child| detect_lowercase_normalizer(Some(child)));
    }
    false
}

fn parse_added_special_tokens(val: Option<&Value>) -> (Option<u32>, Option<u32>, Option<u32>) {
    let Some(arr) = val.and_then(Value::as_array) else {
        return (None, None, None);
    };
    let mut pad = None;
    let mut eos = None;
    let mut unk = None;
    for entry in arr {
        let Some(id) = entry.get("id").and_then(Value::as_u64).map(|v| v as u32) else {
            continue;
        };
        let Some(content) = entry.get("content").and_then(Value::as_str) else {
            continue;
        };
        match content {
            "<pad>" | "[PAD]" => pad = Some(id),
            "</s>" | "<|endoftext|>" | "[SEP]" => eos = Some(id),
            "<unk>" | "[UNK]" => unk = Some(id),
            _ => {}
        }
    }
    (pad, eos, unk)
}

fn parse_unigram_model(
    model_val: &Value,
    added_unk: Option<u32>,
) -> Result<TokenizerModel, MediaWorkerError> {
    let vocab_arr = model_val
        .get("vocab")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            MediaWorkerError::inference_failed("Unigram tokenizer.json missing 'model.vocab' array")
        })?;
    if vocab_arr.is_empty() {
        return Err(MediaWorkerError::inference_failed(
            "Unigram tokenizer.json has empty vocab",
        ));
    }

    let mut pieces = HashMap::with_capacity(vocab_arr.len());
    let mut max_piece_bytes = 1usize;
    for (idx, item) in vocab_arr.iter().enumerate() {
        let pair = item.as_array().ok_or_else(|| {
            MediaWorkerError::inference_failed(format!(
                "Unigram vocab entry {idx} is not a [piece, score] pair"
            ))
        })?;
        let piece = pair.first().and_then(Value::as_str).ok_or_else(|| {
            MediaWorkerError::inference_failed(format!(
                "Unigram vocab entry {idx} missing piece string"
            ))
        })?;
        let score = pair.get(1).and_then(Value::as_f64).unwrap_or(-10.0);
        max_piece_bytes = max_piece_bytes.max(piece.len());
        pieces.insert(piece.to_string(), (idx as u32, score));
    }

    let unk_id = model_val
        .get("unk_id")
        .and_then(Value::as_u64)
        .map(|v| v as u32)
        .or(added_unk)
        .unwrap_or(0)
        .min((vocab_arr.len() - 1) as u32);

    Ok(TokenizerModel::Unigram {
        pieces,
        max_piece_bytes,
        unk_id,
        vocab_size: vocab_arr.len(),
    })
}

fn parse_bpe_model(
    model_val: &Value,
    added_unk: Option<u32>,
) -> Result<TokenizerModel, MediaWorkerError> {
    let vocab_obj = model_val
        .get("vocab")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            MediaWorkerError::inference_failed("BPE tokenizer.json missing 'model.vocab' object")
        })?;
    if vocab_obj.is_empty() {
        return Err(MediaWorkerError::inference_failed(
            "BPE tokenizer.json has empty vocab",
        ));
    }

    let mut vocab = HashMap::with_capacity(vocab_obj.len());
    let mut max_id = 0usize;
    for (tok, id_val) in vocab_obj {
        let id = id_val.as_u64().ok_or_else(|| {
            MediaWorkerError::inference_failed(format!("non-integer token id for '{tok}'"))
        })? as u32;
        max_id = max_id.max(id as usize);
        vocab.insert(tok.clone(), id);
    }

    let mut merges = HashMap::new();
    if let Some(merge_arr) = model_val.get("merges").and_then(Value::as_array) {
        for (rank, entry) in merge_arr.iter().enumerate() {
            if let Some(s) = entry.as_str() {
                if let Some((a, b)) = s.split_once(' ') {
                    merges.insert((a.to_string(), b.to_string()), rank);
                }
            } else if let Some(pair) = entry.as_array()
                && pair.len() == 2
                && let (Some(a), Some(b)) = (pair[0].as_str(), pair[1].as_str())
            {
                merges.insert((a.to_string(), b.to_string()), rank);
            }
        }
    }

    let unk_id = model_val
        .get("unk_token")
        .and_then(Value::as_str)
        .and_then(|tok| vocab.get(tok).copied())
        .or(added_unk)
        .unwrap_or(0);

    let end_of_word_suffix = model_val
        .get("end_of_word_suffix")
        .and_then(Value::as_str)
        .map(str::to_string);

    Ok(TokenizerModel::Bpe {
        vocab,
        merges,
        unk_id,
        end_of_word_suffix,
        vocab_size: max_id + 1,
    })
}

fn parse_wordpiece_model(
    model_val: &Value,
    added_unk: Option<u32>,
) -> Result<TokenizerModel, MediaWorkerError> {
    let vocab_obj = model_val
        .get("vocab")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            MediaWorkerError::inference_failed(
                "WordPiece tokenizer.json missing 'model.vocab' object",
            )
        })?;
    if vocab_obj.is_empty() {
        return Err(MediaWorkerError::inference_failed(
            "WordPiece tokenizer.json has empty vocab",
        ));
    }

    let mut vocab = HashMap::with_capacity(vocab_obj.len());
    let mut max_id = 0usize;
    for (tok, id_val) in vocab_obj {
        let id = id_val.as_u64().ok_or_else(|| {
            MediaWorkerError::inference_failed(format!("non-integer token id for '{tok}'"))
        })? as u32;
        max_id = max_id.max(id as usize);
        vocab.insert(tok.clone(), id);
    }

    let continuing_prefix = model_val
        .get("continuing_subword_prefix")
        .and_then(Value::as_str)
        .unwrap_or("##")
        .to_string();

    let unk_id = model_val
        .get("unk_token")
        .and_then(Value::as_str)
        .and_then(|tok| vocab.get(tok).copied())
        .or(added_unk)
        .unwrap_or(0);

    Ok(TokenizerModel::WordPiece {
        vocab,
        continuing_prefix,
        unk_id,
        vocab_size: max_id + 1,
    })
}

fn normalize_text(text: &str, lowercase: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut prev_space = true;
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !prev_space {
                out.push(' ');
                prev_space = true;
            }
        } else {
            if lowercase {
                for lc in ch.to_lowercase() {
                    out.push(lc);
                }
            } else {
                out.push(ch);
            }
            prev_space = false;
        }
    }
    if out.ends_with(' ') {
        out.pop();
    }
    out
}

fn encode_unigram(
    normalized: &str,
    pieces: &HashMap<String, (u32, f64)>,
    max_piece_bytes: usize,
    unk_id: u32,
) -> Vec<u32> {
    let mut sp = String::with_capacity(normalized.len() + 3);
    sp.push(METASPACE);
    for ch in normalized.chars() {
        if ch == ' ' {
            sp.push(METASPACE);
        } else {
            sp.push(ch);
        }
    }

    let n = sp.len();
    let mut best_score = vec![f64::NEG_INFINITY; n + 1];
    let mut best_prev: Vec<(usize, u32)> = vec![(0, unk_id); n + 1];
    best_score[0] = 0.0;

    let char_boundaries: Vec<usize> = sp
        .char_indices()
        .map(|(idx, _)| idx)
        .chain(std::iter::once(n))
        .collect();

    for window_idx in 0..char_boundaries.len() - 1 {
        let start = char_boundaries[window_idx];
        if !best_score[start].is_finite() {
            continue;
        }
        let mut matched_any = false;
        for &end in &char_boundaries[window_idx + 1..] {
            if end - start > max_piece_bytes {
                break;
            }
            let slice = &sp[start..end];
            if let Some(&(id, score)) = pieces.get(slice) {
                matched_any = true;
                let cand = best_score[start] + score;
                if cand > best_score[end] {
                    best_score[end] = cand;
                    best_prev[end] = (start, id);
                }
            }
        }
        if !matched_any {
            let next = char_boundaries[window_idx + 1];
            let cand = best_score[start] - 25.0;
            if cand > best_score[next] {
                best_score[next] = cand;
                best_prev[next] = (start, unk_id);
            }
        }
    }

    let mut ids = Vec::new();
    let mut pos = n;
    while pos > 0 {
        let (prev, id) = best_prev[pos];
        ids.push(id);
        if prev >= pos {
            break;
        }
        pos = prev;
    }
    ids.reverse();
    ids
}

fn encode_bpe(
    normalized: &str,
    vocab: &HashMap<String, u32>,
    merges: &HashMap<(String, String), usize>,
    unk_id: u32,
    end_of_word_suffix: Option<&str>,
) -> Vec<u32> {
    let mut out = Vec::new();
    for word in normalized.split_whitespace() {
        let mut symbols: Vec<String> = word.chars().map(|c| c.to_string()).collect();
        if let Some(suffix) = end_of_word_suffix
            && let Some(last) = symbols.last_mut()
        {
            last.push_str(suffix);
        }

        loop {
            if symbols.len() < 2 {
                break;
            }
            let mut best: Option<(usize, usize)> = None;
            for i in 0..symbols.len() - 1 {
                let key = (symbols[i].clone(), symbols[i + 1].clone());
                if let Some(&rank) = merges.get(&key)
                    && best.is_none_or(|(best_rank, _)| rank < best_rank)
                {
                    best = Some((rank, i));
                }
            }
            let Some((_, idx)) = best else {
                break;
            };
            let merged = format!("{}{}", symbols[idx], symbols[idx + 1]);
            symbols.splice(idx..=idx + 1, std::iter::once(merged));
        }

        for sym in symbols {
            out.push(vocab.get(&sym).copied().unwrap_or(unk_id));
        }
    }
    out
}

fn encode_wordpiece(
    normalized: &str,
    vocab: &HashMap<String, u32>,
    continuing_prefix: &str,
    unk_id: u32,
) -> Vec<u32> {
    let mut out = Vec::new();
    for word in normalized.split_whitespace() {
        let chars: Vec<char> = word.chars().collect();
        let mut start = 0usize;
        let mut word_ids = Vec::new();
        let mut failed = false;

        while start < chars.len() {
            let mut end = chars.len();
            let mut found = None;
            while end > start {
                let sub: String = chars[start..end].iter().collect();
                let candidate = if start == 0 {
                    sub
                } else {
                    format!("{continuing_prefix}{sub}")
                };
                if let Some(&id) = vocab.get(&candidate) {
                    found = Some((id, end));
                    break;
                }
                end -= 1;
            }
            match found {
                Some((id, next_start)) => {
                    word_ids.push(id);
                    start = next_start;
                }
                None => {
                    failed = true;
                    break;
                }
            }
        }

        if failed {
            out.push(unk_id);
        } else {
            out.extend(word_ids);
        }
    }
    out
}
