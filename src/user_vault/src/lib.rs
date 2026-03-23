use candid::{CandidType, Principal};
use ic_cdk::{query, update};
use serde::{Deserialize, Serialize};

// ── Type aliases matching the .did ─────────────────────────────────────────

type FilePath = String;
type DeviceId = String;
type ContentHash = String;
type Timestamp = u64;

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct VectorClockEntry {
    device_id: DeviceId,
    counter: u64,
}

type VectorClock = Vec<VectorClockEntry>;

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct FileRecord {
    path: FilePath,
    content_hash: ContentHash,
    size_bytes: u64,
    modified_ts: Timestamp,
    device_id: DeviceId,
    vector_clock: VectorClock,
    conflicted: bool,
}

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct FileBlob {
    record_: FileRecord,
    encrypted_bytes: Vec<u8>,
}

#[derive(CandidType, Deserialize)]
struct PushFileRequest {
    path: FilePath,
    encrypted_bytes: Vec<u8>,
    device_id: DeviceId,
    vector_clock: VectorClock,
}

#[derive(CandidType, Deserialize)]
struct PullChangesRequest {
    device_id: DeviceId,
    last_vector_clock: VectorClock,
}

#[derive(CandidType, Deserialize)]
struct ResolveConflictRequest {
    path: FilePath,
    chosen_version: u8,
}

#[derive(CandidType)]
enum ObSyncError {
    NotFound(String),
    Unauthorized,
    ConflictExists(String),
    InvalidInput(String),
    StorageFull,
    InternalError(String),
}

type PushResult = Result<FileRecord, ObSyncError>;
type PullResult = Result<Vec<FileBlob>, ObSyncError>;
type ListResult = Result<Vec<FileRecord>, ObSyncError>;
type ResolveResult = Result<FileRecord, ObSyncError>;

// ── Service methods (stubs) ────────────────────────────────────────────────

#[update]
fn push_file(_req: PushFileRequest) -> PushResult {
    Err(ObSyncError::InternalError("not implemented".to_string()))
}

#[query]
fn pull_changes(_req: PullChangesRequest) -> PullResult {
    Ok(vec![])
}

#[query]
fn list_files() -> ListResult {
    Ok(vec![])
}

#[update]
fn resolve_conflict(_req: ResolveConflictRequest) -> ResolveResult {
    Err(ObSyncError::InternalError("not implemented".to_string()))
}

#[update]
fn clear_vault() -> Result<(), String> {
    Ok(())
}

#[update]
fn drain_and_prepare_delete(_refund_target: Principal) -> Result<u64, String> {
    Ok(0)
}
