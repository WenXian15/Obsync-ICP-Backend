use candid::{CandidType, Principal};
use ic_cdk::{query, update, caller};
use ic_stable_structures::{
    memory_manager::{MemoryId, MemoryManager, VirtualMemory},
    DefaultMemoryImpl, StableBTreeMap,
};
use std::cell::RefCell;

type Memory = VirtualMemory<DefaultMemoryImpl>;

// A BTreeMap stored in stable memory — survives canister upgrades.
// Key:   Principal  (the user's Internet Identity principal)
// Value: Principal  (their vault canister ID — canisters are addressed by principal)
type VaultMap = StableBTreeMap<StorablePrincipal, StorablePrincipal, Memory>;

thread_local! {
    static MEMORY_MANAGER: RefCell<MemoryManager<DefaultMemoryImpl>> =
        RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));

    static VAULT_MAP: RefCell<VaultMap> = RefCell::new(
        StableBTreeMap::init(
            MEMORY_MANAGER.with(|m| m.borrow().get(MemoryId::new(0)))
        )
    );
}

// ── Storable wrapper for Principal ──────────────────────────────────────────
// ic-stable-structures requires keys/values to implement Storable.
// Principal doesn't implement it out of the box, so we wrap it.

use ic_stable_structures::storable::Bound;
use ic_stable_structures::Storable;
use std::borrow::Cow;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct StorablePrincipal(Principal);

impl Storable for StorablePrincipal {
    fn to_bytes(&self) -> Cow<[u8]> {
        Cow::Owned(self.0.as_slice().to_vec())
    }

    fn into_bytes(self) -> Vec<u8> {
        self.0.as_slice().to_vec()
    }

    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        StorablePrincipal(Principal::from_slice(&bytes))
    }

    const BOUND: Bound = Bound::Bounded {
        max_size: 29, // ICP principals are at most 29 bytes
        is_fixed_size: false,
    };
}

// ── Return types ─────────────────────────────────────────────────────────────

#[derive(CandidType)]
enum RegisterResult {
    Ok(Principal),
    Err(String),
}

#[derive(CandidType)]
enum LookupResult {
    Ok(Principal),
    Err(String),
}

// Query Method

#[query]
fn get_vault_id() -> LookupResult {
    let user = StorablePrincipal(caller());

    VAULT_MAP.with(|map| match map.borrow().get(&user) {
        Some(vault_id) => LookupResult::Ok(vault_id.0),
        None           => LookupResult::Err("not_found".to_string()),
    })
}

// Returns true if the caller already has a registered vault
#[query]
fn is_registered() -> bool {
    let user = StorablePrincipal(caller());

    VAULT_MAP.with(|map| map.borrow().contains_key(&user))
}

// Update Method
#[update]
fn register_vault(vault_id: Principal) -> RegisterResult {
    let user = StorablePrincipal(caller());

    // Reject the anonymous principal — II-authenticated users only.
    if caller() == Principal::anonymous() {
        return RegisterResult::Err("anonymous_not_allowed".to_string());
    }

    VAULT_MAP.with(|map| {
        map.borrow_mut().insert(user, StorablePrincipal(vault_id));
    });

    RegisterResult::Ok(vault_id)
}

// Removes the caller's vault registration from the router
// Does not delete the underlying canister
#[update]
fn delete_vault_registration() -> Result<(), String> {
    let user = StorablePrincipal(caller());

    VAULT_MAP.with(|map| {
        if map.borrow_mut().remove(&user).is_some() {
            Ok(())
        } else {
            Err("not_found".to_string())
        }
    })    
}
