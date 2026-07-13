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
    fs::create_dir_all(ledger_dir).map_err(io_error)?;
    let _lock = DirectoryLock::acquire(ledger_dir)?;
    let save = SaveContainer::load(save_path)?;
    let original_hash = sha256(&save.raw);
    let current = player_records(&save.decompressed)?;
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

    if !missing.is_empty() {
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
    }

    Ok(Outcome {
        current_records: current_identities.len(),
        ledger_updates,
        restored_records: missing.len(),
    })
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
}
