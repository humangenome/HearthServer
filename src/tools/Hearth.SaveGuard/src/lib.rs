use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const BLOCK: usize = 131_072;
const PACKAGE_FILE_TAG: [u8; 4] = [0xc1, 0x83, 0x2a, 0x9e];
const MIN_RICH_RECORD_BYTES: usize = 512;
const MIN_PROGRESSED_WORLD_RECORDS: usize = 20;
const MAX_STARTER_WORLD_RECORDS: usize = 12;
const WORLD_BASELINE_FILE: &str = "world-baseline.sav";
const ROTATING_SAVE_NAMES: [&str; 4] = [
    "TEMP_auto.sav",
    "TEMP_auto.sav_backup0",
    "TEMP_auto_today.sav",
    "TEMP_auto_yesterday.sav",
];

#[derive(Debug)]
pub enum Error {
    Io(String),
    BadFile(String),
    Decompress(String),
    Parse(String),
    Race,
    LockTimeout,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(s) => write!(f, "file error: {s}"),
            Error::BadFile(s) => write!(f, "invalid Bellwright save: {s}"),
            Error::Decompress(s) => write!(f, "save decompression failed: {s}"),
            Error::Parse(s) => write!(f, "save structure error: {s}"),
            Error::Race => write!(f, "save changed during protection; refusing to replace it"),
            Error::LockTimeout => write!(f, "another save protection pass did not finish in time"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    pub current_records: usize,
    pub ledger_updates: usize,
    pub restored_records: usize,
    pub world_records: usize,
    pub world_restored: bool,
    pub world_regression_detected: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct WorldMetrics {
    progress_records: usize,
}

struct WorldRecovery {
    save: SaveContainer,
    original_hash: [u8; 32],
    restored: bool,
    regression_detected: bool,
}

#[derive(Clone)]
struct Chunk {
    comp: usize,
    uncomp: usize,
    data_off: usize,
    table: [u8; 16],
}

struct SaveContainer {
    raw: Vec<u8>,
    decompressed: Vec<u8>,
    table_off: usize,
    summary_off: usize,
    totalcopy_off: usize,
    data_start: usize,
    chunks: Vec<Chunk>,
}

impl SaveContainer {
    fn load(path: &Path) -> Result<Self, Error> {
        let raw = fs::read(path).map_err(io_error)?;
        Self::from_bytes(raw)
    }

    fn from_bytes(raw: Vec<u8>) -> Result<Self, Error> {
        if raw.len() < 0x500 || raw.get(0..4) != Some(b"VSWB") {
            return Err(Error::BadFile("missing VSWB magic".into()));
        }
        let total = u64::from_le_bytes(
            raw.get(0x18..0x20)
                .ok_or_else(|| Error::BadFile("missing size header".into()))?
                .try_into()
                .map_err(|_| Error::BadFile("invalid size header".into()))?,
        ) as usize;
        if total == 0 || total > (1usize << 30) {
            return Err(Error::BadFile("implausible uncompressed size".into()));
        }

        let search_end = raw.len().min(0x4000);
        let tag = raw[..search_end]
            .windows(4)
            .position(|w| w == PACKAGE_FILE_TAG)
            .ok_or_else(|| Error::BadFile("compression container tag not found".into()))?;
        let table_off = tag + 0x20;
        let summary_off = tag + 0x11;
        let totalcopy_off = tag + 0x19;
        let nchunks = total.div_ceil(BLOCK);
        let data_start = table_off
            .checked_add(nchunks * 16 + 1)
            .ok_or_else(|| Error::BadFile("chunk table overflow".into()))?;
        if data_start >= raw.len() {
            return Err(Error::BadFile("chunk table overruns file".into()));
        }

        let mut chunks = Vec::with_capacity(nchunks);
        let mut decompressed = Vec::with_capacity(total);
        let mut extractor = oozextract::Extractor::new();
        let mut pos = data_start;
        for index in 0..nchunks {
            let b = table_off + index * 16;
            let table_slice = raw
                .get(b..b + 16)
                .ok_or_else(|| Error::BadFile(format!("chunk {index} table entry missing")))?;
            let mut table = [0u8; 16];
            table.copy_from_slice(table_slice);
            let comp = read_u24(&table, 1);
            let uncomp = read_u24(&table, 9);
            if comp == 0 || uncomp == 0 || uncomp > BLOCK || pos + comp > raw.len() {
                return Err(Error::BadFile(format!("chunk {index} is out of bounds")));
            }
            let compressed = &raw[pos..pos + comp];
            if compressed.first() == Some(&0xcc) && comp == uncomp + 2 {
                decompressed.extend_from_slice(&compressed[2..2 + uncomp]);
            } else {
                let mut decoded = vec![0u8; uncomp];
                extractor
                    .read_from_slice(compressed, &mut decoded)
                    .map_err(|e| Error::Decompress(format!("chunk {index}: {e:?}")))?;
                decompressed.extend_from_slice(&decoded);
            }
            chunks.push(Chunk {
                comp,
                uncomp,
                data_off: pos,
                table,
            });
            pos += comp;
        }
        if pos != raw.len() {
            return Err(Error::BadFile(
                "unexpected bytes after compressed payload".into(),
            ));
        }
        if decompressed.len() != total {
            return Err(Error::Decompress(format!(
                "decoded {} bytes but header declares {total}",
                decompressed.len()
            )));
        }

        Ok(Self {
            raw,
            decompressed,
            table_off,
            summary_off,
            totalcopy_off,
            data_start,
            chunks,
        })
    }

    fn append_player_records(&self, records: &[Vec<u8>]) -> Result<Vec<u8>, Error> {
        if records.is_empty() {
            return Ok(self.raw.clone());
        }
        let mut suffix = Vec::new();
        for record in records {
            suffix.push(0x1a); // top-level repeated field 3, wire type 2
            suffix.extend_from_slice(&encode_varint(record.len() as u64));
            suffix.extend_from_slice(record);
        }

        let prefix_count = self.chunks.len().saturating_sub(1);
        let tail_start: usize = self.chunks[..prefix_count].iter().map(|c| c.uncomp).sum();
        let mut tail = self.decompressed[tail_start..].to_vec();
        tail.extend_from_slice(&suffix);
        let tail_count = tail.len().div_ceil(BLOCK);
        let new_count = prefix_count + tail_count;
        if new_count == 0 {
            return Err(Error::BadFile("save contains no chunks".into()));
        }

        let template = self
            .chunks
            .last()
            .ok_or_else(|| Error::BadFile("save contains no chunks".into()))?
            .table;
        let mut tables = Vec::<[u8; 16]>::with_capacity(new_count);
        for chunk in &self.chunks[..prefix_count] {
            tables.push(chunk.table);
        }
        let mut tail_tables = Vec::with_capacity(tail_count);
        for part in tail.chunks(BLOCK) {
            let mut entry = template;
            write_u24(&mut entry, 1, part.len() + 2)?;
            write_u24(&mut entry, 9, part.len())?;
            tail_tables.push(entry);
        }
        tables.extend(tail_tables.iter().copied());

        let new_data_start = self.table_off + new_count * 16 + 1;
        let prefix_comp: usize = self.chunks[..prefix_count].iter().map(|c| c.comp).sum();
        let mut out =
            Vec::with_capacity(new_data_start + prefix_comp + tail.len() + tail_count * 2);
        out.extend_from_slice(&self.raw[..self.table_off]);
        for table in &tables {
            out.extend_from_slice(table);
        }
        out.push(self.raw[self.data_start - 1]);
        for chunk in &self.chunks[..prefix_count] {
            out.extend_from_slice(&self.raw[chunk.data_off..chunk.data_off + chunk.comp]);
        }
        for part in tail.chunks(BLOCK) {
            out.extend_from_slice(&[0xcc, 0x06]);
            out.extend_from_slice(part);
        }

        let new_total = self.decompressed.len() + suffix.len();
        out[0x18..0x20].copy_from_slice(&(new_total as u64).to_le_bytes());
        out[self.totalcopy_off..self.totalcopy_off + 4]
            .copy_from_slice(&(new_total as u32).to_le_bytes());
        let sum_comp: usize = tables.iter().map(|entry| read_u24(entry, 1)).sum();
        out[self.summary_off..self.summary_off + 4]
            .copy_from_slice(&(sum_comp as u32).to_le_bytes());
        Ok(out)
    }
}

pub fn protect(save_path: &Path, ledger_dir: &Path) -> Result<Outcome, Error> {
    protect_with_mode(save_path, ledger_dir, true)
}

pub fn protect_live(save_path: &Path, ledger_dir: &Path) -> Result<Outcome, Error> {
    protect_with_mode(save_path, ledger_dir, false)
}

fn protect_with_mode(
    save_path: &Path,
    ledger_dir: &Path,
    allow_world_recovery: bool,
) -> Result<Outcome, Error> {
    fs::create_dir_all(ledger_dir).map_err(io_error)?;
    let _lock = DirectoryLock::acquire(ledger_dir)?;
    let recovery = if allow_world_recovery {
        recover_world(save_path, ledger_dir)?
    } else {
        inspect_live_world(save_path, ledger_dir)?
    };
    let save = recovery.save;
    let original_hash = recovery.original_hash;
    let world = world_metrics(&save.decompressed)?;
    let current = player_records(&save.decompressed)?;

    if recovery.regression_detected {
        let current_identities = current
            .iter()
            .filter_map(|record| record_identity(record).transpose())
            .collect::<Result<BTreeSet<_>, _>>()?;
        return Ok(Outcome {
            current_records: current_identities.len(),
            ledger_updates: 0,
            restored_records: 0,
            world_records: world.progress_records,
            world_restored: false,
            world_regression_detected: true,
        });
    }

    let mut ledger = load_ledger(ledger_dir)?;
    let mut current_identities = BTreeSet::new();
    let mut ledger_updates = 0usize;

    for record in &current {
        let Some(identity) = record_identity(record)? else {
            continue;
        };
        current_identities.insert(identity.clone());
        if record.len() < MIN_RICH_RECORD_BYTES {
            if ledger.contains_key(&identity) {
                return Err(Error::Parse(
                    "a truncated player record conflicts with the protected ledger".into(),
                ));
            }
            continue;
        }
        if ledger.get(&identity) != Some(record) {
            write_ledger_record(ledger_dir, &identity, record)?;
            ledger.insert(identity, record.clone());
            ledger_updates += 1;
        }
    }

    let missing: Vec<Vec<u8>> = ledger
        .iter()
        .filter(|(identity, _)| !current_identities.contains(*identity))
        .map(|(_, record)| record.clone())
        .collect();

    let protected_bytes = if !missing.is_empty() {
        let output = save.append_player_records(&missing)?;
        let verified = SaveContainer::from_bytes(output.clone())?;
        let verified_records = player_records(&verified.decompressed)?;
        let verified_ids: BTreeSet<String> = verified_records
            .iter()
            .filter_map(|record| record_identity(record).transpose())
            .collect::<Result<_, _>>()?;
        if !ledger
            .keys()
            .all(|identity| verified_ids.contains(identity))
        {
            return Err(Error::Parse(
                "protected output failed player-record verification".into(),
            ));
        }
        let current_bytes = fs::read(save_path).map_err(io_error)?;
        if sha256(&current_bytes) != original_hash {
            return Err(Error::Race);
        }
        write_atomic(save_path, &output)?;
        output
    } else {
        save.raw.clone()
    };

    write_atomic(&ledger_dir.join(WORLD_BASELINE_FILE), &protected_bytes)?;

    Ok(Outcome {
        current_records: current_identities.len(),
        ledger_updates,
        restored_records: missing.len(),
        world_records: world.progress_records,
        world_restored: recovery.restored,
        world_regression_detected: false,
    })
}

fn inspect_live_world(save_path: &Path, ledger_dir: &Path) -> Result<WorldRecovery, Error> {
    let canonical = SaveContainer::load(save_path)?;
    let original_hash = sha256(&canonical.raw);
    let canonical_metrics = world_metrics(&canonical.decompressed)?;
    let baseline_path = ledger_dir.join(WORLD_BASELINE_FILE);
    let regression_detected = if baseline_path.exists() {
        let baseline = SaveContainer::load(&baseline_path)?;
        catastrophic_regression(world_metrics(&baseline.decompressed)?, canonical_metrics)
    } else {
        false
    };

    Ok(WorldRecovery {
        save: canonical,
        original_hash,
        restored: false,
        regression_detected,
    })
}

fn recover_world(save_path: &Path, ledger_dir: &Path) -> Result<WorldRecovery, Error> {
    let canonical = SaveContainer::load(save_path)?;
    let original_hash = sha256(&canonical.raw);
    let canonical_metrics = world_metrics(&canonical.decompressed)?;
    let baseline_path = ledger_dir.join(WORLD_BASELINE_FILE);

    let baseline = if baseline_path.exists() {
        Some(SaveContainer::load(&baseline_path)?)
    } else {
        None
    };

    let mut progressed = Vec::<(u8, SystemTime, SaveContainer)>::new();
    let mut starter_present = canonical_metrics.progress_records <= MAX_STARTER_WORLD_RECORDS;
    if canonical_metrics.progress_records >= MIN_PROGRESSED_WORLD_RECORDS {
        progressed.push((
            rotating_save_priority(save_path),
            modified_or_epoch(save_path),
            SaveContainer::from_bytes(canonical.raw.clone())?,
        ));
    }

    if let Some(save_dir) = save_path.parent() {
        for name in ROTATING_SAVE_NAMES {
            let path = save_dir.join(name);
            if paths_equal(&path, save_path) || !path.is_file() {
                continue;
            }
            let Ok(candidate) = SaveContainer::load(&path) else {
                continue;
            };
            let metrics = world_metrics(&candidate.decompressed)?;
            if metrics.progress_records >= MIN_PROGRESSED_WORLD_RECORDS {
                progressed.push((
                    rotating_save_priority(&path),
                    modified_or_epoch(&path),
                    candidate,
                ));
            } else if metrics.progress_records <= MAX_STARTER_WORLD_RECORDS {
                starter_present = true;
            }
        }
    }

    progressed.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let rotation_recovery = starter_present && !progressed.is_empty();
    let baseline_recovery = baseline.as_ref().is_some_and(|candidate| {
        world_metrics(&candidate.decompressed)
            .map(|metrics| catastrophic_regression(metrics, canonical_metrics))
            .unwrap_or(false)
    });

    let selected = if baseline_recovery {
        baseline
    } else if rotation_recovery {
        progressed.pop().map(|(_, _, candidate)| candidate)
    } else {
        None
    };

    let Some(selected) = selected else {
        return Ok(WorldRecovery {
            save: canonical,
            original_hash,
            restored: false,
            regression_detected: false,
        });
    };

    let current_bytes = fs::read(save_path).map_err(io_error)?;
    if sha256(&current_bytes) != original_hash {
        return Err(Error::Race);
    }
    normalize_rotating_saves(save_path, &selected.raw)?;
    let restored = SaveContainer::load(save_path)?;
    Ok(WorldRecovery {
        original_hash: sha256(&restored.raw),
        save: restored,
        restored: true,
        regression_detected: false,
    })
}

fn normalize_rotating_saves(save_path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let Some(save_dir) = save_path.parent() else {
        return Err(Error::Io("save target has no parent".into()));
    };
    write_atomic(save_path, bytes)?;
    for name in ROTATING_SAVE_NAMES {
        let path = save_dir.join(name);
        if paths_equal(&path, save_path) || !path.exists() {
            continue;
        }
        write_atomic(&path, bytes)?;
    }
    Ok(())
}

fn world_metrics(payload: &[u8]) -> Result<WorldMetrics, Error> {
    let mut progress_records = 0usize;
    let mut pos = 0usize;
    while pos < payload.len() {
        let key = read_varint(payload, &mut pos)?;
        let field = key >> 3;
        match key & 7 {
            0 => {
                let _ = read_varint(payload, &mut pos)?;
            }
            1 => advance(&mut pos, 8, payload.len())?,
            2 => {
                let len = read_varint(payload, &mut pos)? as usize;
                let end = pos
                    .checked_add(len)
                    .filter(|end| *end <= payload.len())
                    .ok_or_else(|| {
                        Error::Parse("length-delimited field overruns payload".into())
                    })?;
                if field == 11 {
                    progress_records += 1;
                }
                pos = end;
            }
            5 => advance(&mut pos, 4, payload.len())?,
            wire => {
                return Err(Error::Parse(format!(
                    "unsupported protobuf wire type {wire}"
                )))
            }
        }
    }
    Ok(WorldMetrics { progress_records })
}

fn catastrophic_regression(baseline: WorldMetrics, current: WorldMetrics) -> bool {
    baseline.progress_records >= MIN_PROGRESSED_WORLD_RECORDS
        && current.progress_records <= MAX_STARTER_WORLD_RECORDS
        && current.progress_records.saturating_mul(2) < baseline.progress_records
}

fn modified_or_epoch(path: &Path) -> SystemTime {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .unwrap_or(UNIX_EPOCH)
}

fn rotating_save_priority(path: &Path) -> u8 {
    match path.file_name().and_then(|name| name.to_str()) {
        Some(name) if name.eq_ignore_ascii_case("TEMP_auto.sav") => 4,
        Some(name) if name.eq_ignore_ascii_case("TEMP_auto.sav_backup0") => 3,
        Some(name) if name.eq_ignore_ascii_case("TEMP_auto_today.sav") => 2,
        Some(name) if name.eq_ignore_ascii_case("TEMP_auto_yesterday.sav") => 1,
        _ => 0,
    }
}

fn paths_equal(left: &Path, right: &Path) -> bool {
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

fn player_records(payload: &[u8]) -> Result<Vec<Vec<u8>>, Error> {
    let mut records = Vec::new();
    let mut pos = 0usize;
    while pos < payload.len() {
        let key = read_varint(payload, &mut pos)?;
        let field = key >> 3;
        match key & 7 {
            0 => {
                let _ = read_varint(payload, &mut pos)?;
            }
            1 => advance(&mut pos, 8, payload.len())?,
            2 => {
                let len = read_varint(payload, &mut pos)? as usize;
                let end = pos
                    .checked_add(len)
                    .filter(|end| *end <= payload.len())
                    .ok_or_else(|| {
                        Error::Parse("length-delimited field overruns payload".into())
                    })?;
                if field == 3 {
                    records.push(payload[pos..end].to_vec());
                }
                pos = end;
            }
            5 => advance(&mut pos, 4, payload.len())?,
            wire => {
                return Err(Error::Parse(format!(
                    "unsupported protobuf wire type {wire}"
                )))
            }
        }
    }
    Ok(records)
}

fn record_identity(record: &[u8]) -> Result<Option<String>, Error> {
    let marker = b"NULL:";
    let mut found = BTreeSet::new();
    let mut pos = 0usize;
    while pos + marker.len() <= record.len() {
        if &record[pos..pos + marker.len()] != marker {
            pos += 1;
            continue;
        }
        let start = pos + marker.len();
        let mut separator = start;
        while separator < record.len() && separator - start <= 128 {
            let byte = record[separator];
            if byte == b'-' && separator > start && separator + 33 <= record.len() {
                let platform = &record[start..separator];
                let hex = &record[separator + 1..separator + 33];
                if platform
                    .iter()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
                    && hex.iter().all(|b| b.is_ascii_hexdigit())
                {
                    let platform_text = std::str::from_utf8(platform)
                        .map_err(|_| Error::Parse("player identity is not UTF-8".into()))?;
                    if !platform_text.eq_ignore_ascii_case("server") {
                        let token = std::str::from_utf8(&record[start..separator + 33])
                            .map_err(|_| Error::Parse("player identity is not UTF-8".into()))?;
                        found.insert(format!("NULL:{token}"));
                    }
                }
            }
            if !(byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-')) {
                break;
            }
            separator += 1;
        }
        pos += 1;
    }
    match found.len() {
        0 => Ok(None),
        1 => Ok(found.into_iter().next()),
        _ => Err(Error::Parse(
            "one player record contains multiple identities".into(),
        )),
    }
}

fn load_ledger(dir: &Path) -> Result<BTreeMap<String, Vec<u8>>, Error> {
    let mut ledger = BTreeMap::new();
    for entry in fs::read_dir(dir).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("record") {
            continue;
        }
        let record = fs::read(&path).map_err(io_error)?;
        if record.len() < MIN_RICH_RECORD_BYTES {
            return Err(Error::Parse(
                "protected ledger contains a truncated record".into(),
            ));
        }
        let identity = record_identity(&record)?.ok_or_else(|| {
            Error::Parse("protected ledger contains an unidentified record".into())
        })?;
        let expected_name = format!("{}.record", hex_sha256(identity.as_bytes()));
        if path.file_name().and_then(|s| s.to_str()) != Some(&expected_name) {
            return Err(Error::Parse(
                "protected ledger filename does not match its record".into(),
            ));
        }
        if ledger.insert(identity, record).is_some() {
            return Err(Error::Parse(
                "protected ledger contains a duplicate identity".into(),
            ));
        }
    }
    Ok(ledger)
}

fn write_ledger_record(dir: &Path, identity: &str, record: &[u8]) -> Result<(), Error> {
    let path = dir.join(format!("{}.record", hex_sha256(identity.as_bytes())));
    write_atomic(&path, record)
}

fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, Error> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *pos < data.len() && shift <= 63 {
        let byte = data[*pos];
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
    }
    Err(Error::Parse("invalid protobuf varint".into()))
}

fn encode_varint(mut value: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            return out;
        }
    }
}

fn advance(pos: &mut usize, count: usize, len: usize) -> Result<(), Error> {
    *pos = pos
        .checked_add(count)
        .filter(|next| *next <= len)
        .ok_or_else(|| Error::Parse("fixed-width field overruns payload".into()))?;
    Ok(())
}

fn read_u24(data: &[u8], offset: usize) -> usize {
    data[offset] as usize | ((data[offset + 1] as usize) << 8) | ((data[offset + 2] as usize) << 16)
}

fn write_u24(data: &mut [u8], offset: usize, value: usize) -> Result<(), Error> {
    if value > 0x00ff_ffff {
        return Err(Error::BadFile("chunk size exceeds container limit".into()));
    }
    data[offset] = value as u8;
    data[offset + 1] = (value >> 8) as u8;
    data[offset + 2] = (value >> 16) as u8;
    Ok(())
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = sha256(bytes);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn io_error(error: std::io::Error) -> Error {
    Error::Io(error.to_string())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::Io("target has no parent".into()))?;
    fs::create_dir_all(parent).map_err(io_error)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp = parent.join(format!(
        ".{}.{}.{}.tmp",
        path.file_name().and_then(|s| s.to_str()).unwrap_or("save"),
        std::process::id(),
        nonce
    ));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(io_error)?;
        file.write_all(bytes).map_err(io_error)?;
        file.sync_all().map_err(io_error)?;
        drop(file);
        replace_file(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(windows)]
fn replace_file(source: &Path, target: &Path) -> Result<(), Error> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let source_w: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let target_w: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let ok = unsafe {
        MoveFileExW(
            source_w.as_ptr(),
            target_w.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        return Err(io_error(std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(source: &Path, target: &Path) -> Result<(), Error> {
    fs::rename(source, target).map_err(io_error)
}

struct DirectoryLock {
    path: PathBuf,
    file: Option<File>,
}

impl DirectoryLock {
    fn acquire(dir: &Path) -> Result<Self, Error> {
        let path = dir.join(".protect.lock");
        for _ in 0..200 {
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut file) => {
                    let _ = writeln!(file, "{}", std::process::id());
                    return Ok(Self {
                        path,
                        file: Some(file),
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let stale = fs::metadata(&path)
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|t| t.elapsed().ok())
                        .is_some_and(|age| age > Duration::from_secs(120));
                    if stale {
                        let _ = fs::remove_file(&path);
                    } else {
                        thread::sleep(Duration::from_millis(50));
                    }
                }
                Err(error) => return Err(io_error(error)),
            }
        }
        Err(Error::LockTimeout)
    }
}

impl Drop for DirectoryLock {
    fn drop(&mut self) {
        drop(self.file.take());
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field3(record: &[u8]) -> Vec<u8> {
        let mut out = vec![0x1a];
        out.extend_from_slice(&encode_varint(record.len() as u64));
        out.extend_from_slice(record);
        out
    }

    fn field11(fill: u8) -> Vec<u8> {
        vec![0x5a, 0x01, fill]
    }

    fn world(progress_records: usize, players: &[Vec<u8>]) -> Vec<u8> {
        let mut out = vec![0x08, 0x01];
        for index in 0..progress_records {
            out.extend(field11(index as u8));
        }
        for player in players {
            out.extend(field3(player));
        }
        out
    }

    fn player(identity: &str, fill: u8) -> Vec<u8> {
        let mut out = identity.as_bytes().to_vec();
        out.resize(700, fill);
        out
    }

    fn synthetic_save(payload: &[u8]) -> Vec<u8> {
        let tag = 0x500usize;
        let table_off = tag + 0x20;
        let chunks: Vec<&[u8]> = payload.chunks(BLOCK).collect();
        let data_start = table_off + chunks.len() * 16 + 1;
        let mut raw = vec![0u8; data_start];
        raw[0..4].copy_from_slice(b"VSWB");
        raw[0x18..0x20].copy_from_slice(&(payload.len() as u64).to_le_bytes());
        raw[tag..tag + 4].copy_from_slice(&PACKAGE_FILE_TAG);
        raw[tag + 0x19..tag + 0x1d].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        let mut sum = 0usize;
        for (index, chunk) in chunks.iter().enumerate() {
            let b = table_off + index * 16;
            write_u24(&mut raw[b..b + 16], 1, chunk.len() + 2).unwrap();
            write_u24(&mut raw[b..b + 16], 9, chunk.len()).unwrap();
            raw.extend_from_slice(&[0xcc, 0x06]);
            raw.extend_from_slice(chunk);
            sum += chunk.len() + 2;
        }
        raw[tag + 0x11..tag + 0x15].copy_from_slice(&(sum as u32).to_le_bytes());
        raw
    }

    #[test]
    fn restores_missing_records_and_preserves_current_world() {
        let temp = tempfile::tempdir().unwrap();
        let save_path = temp.path().join("TEMP_auto.sav");
        let ledger = temp.path().join("ledger");
        let george = player("NULL:Havlas-11111111111111111111111111111111", 0x41);
        let kraken = player("NULL:DESKTOP-22222222222222222222222222222222", 0x42);
        let mut full = vec![0x08, 0x01];
        full.extend(field3(&george));
        full.extend(field3(&kraken));
        fs::write(&save_path, synthetic_save(&full)).unwrap();
        let seeded = protect(&save_path, &ledger).unwrap();
        assert_eq!(seeded.ledger_updates, 2);

        let pruned = vec![0x08, 0x02, 0x12, 0x03, b'n', b'e', b'w'];
        fs::write(&save_path, synthetic_save(&pruned)).unwrap();
        let restored = protect(&save_path, &ledger).unwrap();
        assert_eq!(restored.restored_records, 2);
        let parsed = SaveContainer::load(&save_path).unwrap();
        assert!(parsed.decompressed.starts_with(&pruned));
        assert_eq!(player_records(&parsed.decompressed).unwrap().len(), 2);
    }

    #[test]
    fn ignores_server_identity() {
        let temp = tempfile::tempdir().unwrap();
        let save_path = temp.path().join("TEMP_auto.sav");
        let server = player("NULL:server-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0x51);
        fs::write(&save_path, synthetic_save(&field3(&server))).unwrap();
        let result = protect(&save_path, &temp.path().join("ledger")).unwrap();
        assert_eq!(result.current_records, 0);
        assert_eq!(result.ledger_updates, 0);
    }

    #[test]
    fn refuses_truncated_record_over_protected_record() {
        let temp = tempfile::tempdir().unwrap();
        let save_path = temp.path().join("TEMP_auto.sav");
        let ledger = temp.path().join("ledger");
        let identity = "NULL:Havlas-11111111111111111111111111111111";
        fs::write(&save_path, synthetic_save(&field3(&player(identity, 0x41)))).unwrap();
        protect(&save_path, &ledger).unwrap();
        fs::write(&save_path, synthetic_save(&field3(identity.as_bytes()))).unwrap();
        assert!(protect(&save_path, &ledger).is_err());
    }

    #[test]
    fn appended_records_can_cross_a_chunk_boundary() {
        let temp = tempfile::tempdir().unwrap();
        let save_path = temp.path().join("TEMP_auto.sav");
        let ledger = temp.path().join("ledger");
        let identity = "NULL:Havlas-11111111111111111111111111111111";
        fs::write(&save_path, synthetic_save(&field3(&player(identity, 0x41)))).unwrap();
        protect(&save_path, &ledger).unwrap();
        let current = vec![0u8; BLOCK - 100];
        fs::write(&save_path, synthetic_save(&current)).unwrap();
        protect(&save_path, &ledger).unwrap();
        let parsed = SaveContainer::load(&save_path).unwrap();
        assert_eq!(parsed.chunks.len(), 2);
        assert!(parsed.decompressed.starts_with(&current));
    }

    #[test]
    fn repairs_a_mixed_rotating_set_before_protection() {
        let temp = tempfile::tempdir().unwrap();
        let save_dir = temp.path().join("SaveGames");
        let ledger = temp.path().join("ledger");
        fs::create_dir_all(&save_dir).unwrap();
        let george = player("NULL:Havlas-11111111111111111111111111111111", 0x41);
        let progressed_today = synthetic_save(&world(76, std::slice::from_ref(&george)));
        let progressed_yesterday = synthetic_save(&world(68, std::slice::from_ref(&george)));
        let starter = synthetic_save(&world(9, &[]));
        let canonical = save_dir.join("TEMP_auto.sav");
        fs::write(&canonical, &starter).unwrap();
        fs::write(save_dir.join("TEMP_auto.sav_backup0"), &starter).unwrap();
        fs::write(save_dir.join("TEMP_auto_today.sav"), &progressed_today).unwrap();
        fs::write(
            save_dir.join("TEMP_auto_yesterday.sav"),
            &progressed_yesterday,
        )
        .unwrap();

        let outcome = protect(&canonical, &ledger).unwrap();

        assert!(outcome.world_restored);
        assert_eq!(outcome.world_records, 76);
        for name in ROTATING_SAVE_NAMES {
            assert_eq!(fs::read(save_dir.join(name)).unwrap(), progressed_today);
        }
        assert_eq!(
            fs::read(ledger.join(WORLD_BASELINE_FILE)).unwrap(),
            progressed_today
        );
    }

    #[test]
    fn live_protection_detects_regression_without_rewriting_rotation() {
        let temp = tempfile::tempdir().unwrap();
        let save_dir = temp.path().join("SaveGames");
        let ledger = temp.path().join("ledger");
        fs::create_dir_all(&save_dir).unwrap();
        let george = player("NULL:Havlas-11111111111111111111111111111111", 0x41);
        let progressed = synthetic_save(&world(76, std::slice::from_ref(&george)));
        let starter = synthetic_save(&world(9, &[]));
        let canonical = save_dir.join("TEMP_auto.sav");
        for name in ROTATING_SAVE_NAMES {
            fs::write(save_dir.join(name), &progressed).unwrap();
        }
        protect(&canonical, &ledger).unwrap();

        fs::write(&canonical, &starter).unwrap();
        fs::write(save_dir.join("TEMP_auto.sav_backup0"), &starter).unwrap();
        let before: BTreeMap<&str, Vec<u8>> = ROTATING_SAVE_NAMES
            .iter()
            .map(|name| (*name, fs::read(save_dir.join(name)).unwrap()))
            .collect();

        let outcome = protect_live(&canonical, &ledger).unwrap();

        assert!(outcome.world_regression_detected);
        assert!(!outcome.world_restored);
        for name in ROTATING_SAVE_NAMES {
            assert_eq!(fs::read(save_dir.join(name)).unwrap(), before[name]);
        }
        assert_eq!(
            fs::read(ledger.join(WORLD_BASELINE_FILE)).unwrap(),
            progressed
        );
    }

    #[test]
    fn live_protection_does_not_normalize_a_mixed_rotation() {
        let temp = tempfile::tempdir().unwrap();
        let save_dir = temp.path().join("SaveGames");
        let ledger = temp.path().join("ledger");
        fs::create_dir_all(&save_dir).unwrap();
        let canonical_bytes = synthetic_save(&world(80, &[]));
        let starter = synthetic_save(&world(9, &[]));
        let canonical = save_dir.join("TEMP_auto.sav");
        fs::write(&canonical, &canonical_bytes).unwrap();
        fs::write(save_dir.join("TEMP_auto.sav_backup0"), &starter).unwrap();

        let outcome = protect_live(&canonical, &ledger).unwrap();

        assert!(!outcome.world_regression_detected);
        assert!(!outcome.world_restored);
        assert_eq!(fs::read(&canonical).unwrap(), canonical_bytes);
        assert_eq!(
            fs::read(save_dir.join("TEMP_auto.sav_backup0")).unwrap(),
            starter
        );
        assert_eq!(
            fs::read(ledger.join(WORLD_BASELINE_FILE)).unwrap(),
            canonical_bytes
        );
    }

    #[test]
    fn restores_the_full_world_from_the_protected_baseline() {
        let temp = tempfile::tempdir().unwrap();
        let save_dir = temp.path().join("SaveGames");
        let ledger = temp.path().join("ledger");
        fs::create_dir_all(&save_dir).unwrap();
        let george = player("NULL:Havlas-11111111111111111111111111111111", 0x41);
        let progressed = synthetic_save(&world(77, std::slice::from_ref(&george)));
        let starter = synthetic_save(&world(9, &[]));
        let canonical = save_dir.join("TEMP_auto.sav");
        for name in ROTATING_SAVE_NAMES {
            fs::write(save_dir.join(name), &progressed).unwrap();
        }
        let seeded = protect(&canonical, &ledger).unwrap();
        assert!(!seeded.world_restored);

        for name in ROTATING_SAVE_NAMES {
            fs::write(save_dir.join(name), &starter).unwrap();
        }
        let restored = protect(&canonical, &ledger).unwrap();

        assert!(restored.world_restored);
        assert_eq!(restored.world_records, 77);
        for name in ROTATING_SAVE_NAMES {
            assert_eq!(fs::read(save_dir.join(name)).unwrap(), progressed);
        }
    }

    #[test]
    fn accepts_an_intentional_starter_world_after_protection_state_is_cleared() {
        let temp = tempfile::tempdir().unwrap();
        let save_dir = temp.path().join("SaveGames");
        let ledger = temp.path().join("ledger");
        fs::create_dir_all(&save_dir).unwrap();
        let canonical = save_dir.join("TEMP_auto.sav");
        fs::write(&canonical, synthetic_save(&world(50, &[]))).unwrap();
        protect(&canonical, &ledger).unwrap();

        fs::remove_dir_all(&ledger).unwrap();
        fs::write(&canonical, synthetic_save(&world(9, &[]))).unwrap();
        let result = protect(&canonical, &ledger).unwrap();

        assert!(!result.world_restored);
        assert_eq!(result.world_records, 9);
    }
}
