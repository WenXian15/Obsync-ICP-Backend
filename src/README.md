Here are the Rust patterns that appear directly in the codebase you're building, grouped by concept.

---

## 1. Ownership & borrowing

The most fundamental thing in Rust. Every value has exactly one owner, and you either **move** it or **borrow** it.

```rust
let a = String::from("hello");
let b = a;          // a is MOVED into b — a is no longer valid
// println!("{a}"); // compile error: value moved

let c = String::from("world");
let d = &c;         // borrow — c still owns the data, d just references it
println!("{c} {d}"); // both valid
```

In the vault code you'll see this constantly with `borrow()` and `borrow_mut()` on `RefCell` — that's the runtime version of the same concept:

```rust
FILE_INDEX.with(|index| {
    index.borrow()     // immutable borrow — for reads
    index.borrow_mut() // mutable borrow — for writes
    // you cannot hold both at the same time — runtime panic if you try
});
```

---

## 2. `Result` and the `?` operator

ICP canister methods return `Result<T, String>` for fallible operations. The `?` operator is shorthand for "return the error early if this failed":

```rust
// Without ?
fn get_conflict(path: String) -> Result<ConflictEntry, String> {
    let result = CONFLICT_LOG.with(|log| log.borrow().get(&StorableString(path)));
    match result {
        Some(c) => Ok(c.0),
        None    => Err("not_found".to_string()),
    }
}

// With ? — same thing, cleaner when chaining multiple fallible calls
fn resolve_conflict(path: String, keep: String) -> Result<(), String> {
    let conflict = get_conflict(path.clone())?;  // returns early if Err
    let chosen = pick_version(&conflict, &keep)?; // returns early if Err
    write_to_index(path, chosen)?;
    Ok(())
}
```

---

## 3. `match` and `if let`

Pattern matching is how you branch on `Result`, `Option`, and enums like `ClockRelation`:

```rust
// match — exhaustive, must cover all variants
match compare_clocks(&stored.vector_clock, &incoming.vector_clock) {
    ClockRelation::Descendant | ClockRelation::Equal => { /* update */ }
    ClockRelation::Ancestor  => { /* discard */ }
    ClockRelation::Concurrent => { /* conflict */ }
}

// if let — when you only care about one variant
if let Some(record) = index.borrow().get(&key) {
    println!("found: {}", record.0.content_hash);
}

// matches! macro — returns bool, good for filter conditions
if matches!(relation, ClockRelation::Ancestor | ClockRelation::Equal) {
    continue;
}
```

---

## 4. Closures and `thread_local!` with `.with()`

All your stable storage lives in `thread_local!` statics. You access them exclusively through `.with()`, which takes a closure:

```rust
// The |index| part is the closure parameter — index is a reference to the RefCell
FILE_INDEX.with(|index| {
    // inside here, index is &RefCell<StableBTreeMap<...>>
    index.borrow().get(&key)  // read
});

// Closures can capture variables from the outer scope
let key = StorableString(path.clone());
FILE_INDEX.with(|index| {
    index.borrow_mut().insert(key, StorableFileRecord(record));
    //                         ^ key is MOVED into the closure
});
```

The key rule: **you cannot return a reference out of `.with()`**. If you need data outside the closure, clone it or collect it into an owned value:

```rust
// WRONG — returns a reference to data inside the RefCell
FILE_INDEX.with(|index| {
    &index.borrow().get(&key) // compile error
})

// RIGHT — clone the value so it outlives the closure
FILE_INDEX.with(|index| {
    index.borrow().get(&key).map(|r| r.0.clone()) // owned Option<FileRecord>
})
```

---

## 5. Iterators

The vault's `list_files` and `pull_changes` both use iterator chains instead of manual loops:

```rust
// Manual loop version
let mut results = Vec::new();
for (k, v) in index.borrow().iter() {
    results.push((k.0.clone(), v.0.clone()));
}

// Iterator chain version — same result, more idiomatic
index.borrow()
    .iter()
    .map(|(k, v)| (k.0.clone(), v.0.clone()))
    .collect::<Vec<_>>()

// filter + map together — used in pull_changes
index.borrow()
    .iter()
    .filter(|(_, v)| is_newer_than(&v.0.vector_clock, &device_clock))
    .map(|(k, v)| FileDelta { path: k.0.clone(), record: v.0.clone(), blob: vec![] })
    .collect()
```

The four methods you'll use most: `.map()`, `.filter()`, `.collect()`, `.any()` / `.all()`.

---

## 6. Structs, `derive`, and `impl`

Your data types are all structs. The `#[derive(...)]` attribute auto-generates trait implementations:

```rust
#[derive(CandidType, Deserialize, Clone)]
//       ^ needed for ICP  ^ needed to  ^ needed to .clone()
//         serialisation     deserialise   the struct
struct FileRecord {
    content_hash: String,
    size_bytes:   u64,
    modified_ts:  u64,
    device_id:    String,
    vector_clock: BTreeMap<String, u64>,
}

// impl block — add methods to your struct
impl FileRecord {
    fn is_newer_than(&self, other: &FileRecord) -> bool {
        self.modified_ts > other.modified_ts
    }
}

// call it
record.is_newer_than(&other_record);
```

---

## 7. Enums

Used for `ClockRelation` and return types like `RegisterResult`:

```rust
// Simple enum — no data attached
enum ClockRelation {
    Ancestor,
    Descendant,
    Concurrent,
    Equal,
}

// Enum with data — each variant can hold different types
// This is what your Candid return types look like
#[derive(CandidType)]
enum RegisterResult {
    Ok(Principal),   // success carries a Principal
    Err(String),     // error carries a message
}

// Rust's built-in Result is the same idea:
// enum Result<T, E> { Ok(T), Err(E) }
```

---

## 8. Traits and `impl Trait for Type`

The `Storable` wrapper pattern is just implementing a trait. A trait is a set of methods a type must provide:

```rust
// The Storable trait (defined by ic-stable-structures) requires these two methods:
pub trait Storable {
    fn to_bytes(&self) -> Cow<[u8]>;
    fn from_bytes(bytes: Cow<[u8]>) -> Self;
    const BOUND: Bound;
}

// You implement it for your wrapper type
struct StorableString(String);  // tuple struct — wraps String

impl Storable for StorableString {
    fn to_bytes(&self) -> Cow<[u8]> {
        Cow::Owned(self.0.as_bytes().to_vec())
        //              ^ .0 accesses the inner String of the tuple struct
    }
    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        StorableString(String::from_utf8(bytes.to_vec()).unwrap())
    }
    const BOUND: Bound = Bound::Bounded { max_size: 1024, is_fixed_size: false };
}
```

---

## 9. `Clone` vs `Copy` and when to use `.clone()`

```rust
// Types that are Copy — cheaply duplicated, no explicit clone needed
let x: u64 = 42;
let y = x;   // x is still valid — u64 is Copy

// Types that are NOT Copy (heap-allocated) — must clone explicitly
let s = String::from("notes/hello.md");
let key = StorableString(s.clone()); // clone s so both variables remain valid
FILE_INDEX.with(|index| {
    index.borrow_mut().insert(key, ...);
    // key is moved here — s is still valid because we cloned it
});
```

In the canister code you'll see `.clone()` heavily on `String`, `Vec<u8>`, and your own structs — any time you need to use a value in two places.

---

## 10. `unwrap()` vs proper error handling

You'll see both in the codebase. Know when each is appropriate:

```rust
// unwrap() — panics if None/Err. OK for cases that should never fail.
// Used in Storable implementations where corruption = unrecoverable anyway.
fn from_bytes(bytes: Cow<[u8]>) -> Self {
    StorableString(String::from_utf8(bytes.to_vec()).unwrap())
}

// .unwrap_or_default() — gives a safe fallback instead of panicking
let blob = store.borrow()
    .get(&hash_key)
    .map(|b| b.0)
    .unwrap_or_default(); // returns empty Vec<u8> if not found

// .ok_or() — converts Option into Result so you can use ?
let conflict = CONFLICT_LOG.with(|log| log.borrow().get(&key))
    .ok_or("no_conflict_found".to_string())?;
//   ^ turns None into Err("no_conflict_found") and returns early
```

---

## Quick reference — patterns by canister method

| Method | Key patterns used |
|---|---|
| `push_file` | `thread_local` + `.with()`, `match`, `entry().or_insert()` |
| `pull_changes` | iterator chain, `.filter()`, `.map()`, `.collect()` |
| `resolve_conflict` | `?` operator, `.ok_or()`, `match` on enum |
| `list_files` | iterator `.map()` + `.collect()` |
| `clear_vault` | `.with()`, `borrow_mut()` |
| Storable impls | `impl Trait for Type`, `Cow`, tuple struct `.0` |