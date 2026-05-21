/// Generic, ordered associative container backed by a deterministically-
/// balanced skip list.
///
/// SortedMap is generic over both key type `K` and value type `V`. Ordering is
/// supplied by a `<` comparator lambda passed at each call site (or implicitly
/// `*a < *b` via the non-`_by` macro wrappers, suitable for unsigned-int keys).
///
/// **Level promotion.** A monotonic insertion counter (`next_id`) determines
/// every node's height: `level = 1 + (largest k such that p_inv^k divides
/// next_id)`. This yields an *exact* geometric distribution — exactly one
/// node in every `p_inv` reaches level ≥ 2, one in every `p_inv^2` reaches
/// level ≥ 3, and so on — so search is worst-case `O(log_{p_inv} N)`, not
/// expected. No randomness, no RNG state, no level-distribution attack
/// surface.
///
/// **Comparator contract.** Every call against the same instance MUST pass a
/// lambda that defines the same total order. Equality is derived as
/// `!lt(a, b) && !lt(b, a)`. Inconsistent comparators silently corrupt the
/// structure (same contract Rust's `BTreeMap` carries with custom `Ord`).
module sorted_map::sorted_map;

use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const EInvalidMaxLevel: vector<u8> = "Invalid Max Level";
#[error(code = 1)]
const EInvalidPInv: vector<u8> = "Invalid P-Inv";
#[error(code = 2)]
const EKeyNotFound: vector<u8> = "Key Not Found";
#[error(code = 3)]
const ENotEmpty: vector<u8> = "Not Empty";

// === Structs ===

public struct SortedMap<K: copy + drop + store, V: store> has key, store {
    /// Identity. Present so the map can stand alone as a shared/owned Sui
    /// object; the `store` ability still allows it to be embedded as a field
    /// in a consumer-defined object. Consumers pick the shape.
    id: UID,
    /// Arena of all live nodes, keyed by `K`. Each entry lives as a dynamic
    /// field — only nodes touched on the search path are loaded per
    /// transaction.
    nodes: Table<K, Node<K, V>>,
    /// Head sentinel forward pointers. `head[0]` is the smallest key and is
    /// `none` iff the map is empty. `length(head) == max_level`.
    head: vector<Option<K>>,
    /// Largest key. `none` iff the map is empty. Maintained for O(1) `tail()`.
    tail: Option<K>,
    /// Highest level currently occupied by any node, `1..=max_level`. Lets
    /// search short-circuit past empty top levels.
    level: u8,
    /// Configured maximum level a node may occupy. Set at construction.
    max_level: u8,
    /// Divisor for level promotion. The k-th level is reached iff `p_inv^k`
    /// divides the insertion counter, so exactly one node in every `p_inv`
    /// insertions occupies level ≥ 2.
    p_inv: u64,
    /// Monotonic insertion counter. Incremented once per `splice_new` and
    /// fed to `next_level` to deterministically assign node heights.
    next_id: u64,
}

public struct Node<K: copy + drop + store, V: store> has store {
    /// Owning key. Duplicated from the Table key for in-node access (e.g. when
    /// a navigation result is dereferenced via `node_key_at`).
    key: K,
    value: V,
    /// `length(nexts) == this node's chosen level (1..=SortedMap.max_level)`.
    /// `nexts[i]` is the next node's key at level `i`, or `none` for end.
    nexts: vector<Option<K>>,
    /// Previous node's key at level 0. `none` iff this node has the smallest
    /// key.
    prev: Option<K>,
}

// === Lifecycle ===

public fun new<K: copy + drop + store, V: store>(
    max_level: u8,
    p_inv: u64,
    ctx: &mut TxContext,
): SortedMap<K, V> {
    assert!(max_level >= 1, EInvalidMaxLevel);
    assert!(p_inv >= 2, EInvalidPInv);
    let mut head: vector<Option<K>> = vector[];
    let mut i: u8 = 0;
    while (i < max_level) {
        head.push_back(option::none());
        i = i + 1;
    };
    SortedMap {
        id: object::new(ctx),
        nodes: table::new(ctx),
        head,
        tail: option::none(),
        level: 1,
        max_level,
        p_inv,
        next_id: 0,
    }
}

public fun destroy_empty<K: copy + drop + store, V: store>(map: SortedMap<K, V>) {
    assert!(map.nodes.is_empty(), ENotEmpty);
    let SortedMap {
        id,
        nodes,
        head: _,
        tail: _,
        level: _,
        max_level: _,
        p_inv: _,
        next_id: _,
    } = map;
    id.delete();
    nodes.destroy_empty();
}

// === Read accessors ===

public fun length<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): u64 {
    map.nodes.length()
}

public fun is_empty<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): bool {
    map.nodes.is_empty()
}

/// Smallest key, or none if empty. O(1).
public fun head<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): Option<K> {
    *map.head.borrow(0)
}

/// Largest key, or none if empty. O(1).
public fun tail<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): Option<K> {
    map.tail
}

/// Current top-of-stack level (1..=max_level). Grows as taller nodes are inserted.
public fun current_level<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): u8 {
    map.level
}

/// Maximum permitted level, fixed at construction.
public fun cap_level<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): u8 {
    map.max_level
}

/// Inverse promotion probability, fixed at construction.
public fun p_inv_of<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): u64 {
    map.p_inv
}

// === Macro-internal accessors ===
//
// Public because Move 2024 macros expand at the call site and must use only
// public symbols. Treat as library-internal.

public fun head_at<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, level: u8): Option<K> {
    *map.head.borrow(level as u64)
}

public fun node_next_at<K: copy + drop + store, V: store>(
    map: &SortedMap<K, V>,
    key: K,
    level: u8,
): Option<K> {
    *map.nodes.borrow(key).nexts.borrow(level as u64)
}

public fun node_key_at<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, key: K): &K {
    &map.nodes.borrow(key).key
}

public fun node_value_at<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, key: K): &V {
    &map.nodes.borrow(key).value
}

public fun node_value_at_mut<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    key: K,
): &mut V {
    &mut map.nodes.borrow_mut(key).value
}

public fun node_prev<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, key: K): Option<K> {
    map.nodes.borrow(key).prev
}

// === Internal mutators ===

/// Deterministic level assignment. Increments the insertion counter and
/// returns `1 + (largest k such that p_inv^k divides next_id)`, capped at
/// `max_level`. This yields an exact geometric distribution: exactly one
/// node in every `p_inv` reaches level ≥ 2, one in every `p_inv^2` reaches
/// level ≥ 3, etc.
fun next_level<K: copy + drop + store, V: store>(map: &mut SortedMap<K, V>): u8 {
    map.next_id = map.next_id + 1;
    let mut c = map.next_id;
    let mut lvl: u8 = 1;
    while (lvl < map.max_level && c % map.p_inv == 0) {
        lvl = lvl + 1;
        c = c / map.p_inv;
    };
    lvl
}

/// Aborts with `EKeyNotFound` when `found` is false. Exists so macro bodies
/// expanded in other modules can raise this error without referencing the
/// module-private constant.
public fun assert_key_found(found: bool) {
    assert!(found, EKeyNotFound);
}

public fun replace<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    key: K,
    new_value: V,
): V {
    assert!(map.nodes.contains(key), EKeyNotFound);
    let Node { key: k, value: old_value, nexts, prev } = map.nodes.remove(key);
    map.nodes.add(key, Node { key: k, value: new_value, nexts, prev });
    old_value
}

/// Splices a new node carrying `(key, value)` into the structure at the
/// position described by `update`. Caller must ensure `key` is not yet present.
public fun splice_new<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    key: K,
    value: V,
    update: vector<Option<K>>,
) {
    let new_lvl = next_level(map);

    // Build node's nexts vector
    let mut nexts: vector<Option<K>> = vector[];
    let mut i: u8 = 0;
    while (i < new_lvl) {
        let pred_opt = *update.borrow(i as u64);
        let next_at_i = if (pred_opt.is_some()) {
            *map.nodes.borrow(*pred_opt.borrow()).nexts.borrow(i as u64)
        } else {
            *map.head.borrow(i as u64)
        };
        nexts.push_back(next_at_i);
        i = i + 1;
    };

    let prev0 = *update.borrow(0);
    let succ0 = *nexts.borrow(0);

    map.nodes.add(key, Node { key, value, nexts, prev: prev0 });

    // Wire predecessors at each level the new node occupies
    let mut i: u8 = 0;
    while (i < new_lvl) {
        let pred_opt = *update.borrow(i as u64);
        if (pred_opt.is_some()) {
            let pred = map.nodes.borrow_mut(*pred_opt.borrow());
            *pred.nexts.borrow_mut(i as u64) = option::some(key);
        } else {
            *map.head.borrow_mut(i as u64) = option::some(key);
        };
        i = i + 1;
    };

    // Wire level-0 successor's prev pointer to new key, or update tail
    if (succ0.is_some()) {
        map.nodes.borrow_mut(*succ0.borrow()).prev = option::some(key);
    } else {
        map.tail = option::some(key);
    };

    if (new_lvl > map.level) {
        map.level = new_lvl;
    };
}

public fun unsplice<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    update: vector<Option<K>>,
    target: K,
): V {
    let target_lvl = (map.nodes.borrow(target).nexts.length() as u8);

    // Splice-out at each level the target occupies
    let mut i: u8 = 0;
    while (i < target_lvl) {
        let target_next_at_i = *map.nodes.borrow(target).nexts.borrow(i as u64);
        let pred_opt = *update.borrow(i as u64);
        if (pred_opt.is_some()) {
            let pred = map.nodes.borrow_mut(*pred_opt.borrow());
            *pred.nexts.borrow_mut(i as u64) = target_next_at_i;
        } else {
            *map.head.borrow_mut(i as u64) = target_next_at_i;
        };
        i = i + 1;
    };

    let target_next0 = *map.nodes.borrow(target).nexts.borrow(0);
    let target_prev0 = map.nodes.borrow(target).prev;
    if (target_next0.is_some()) {
        map.nodes.borrow_mut(*target_next0.borrow()).prev = target_prev0;
    };

    if (map.tail.is_some() && *map.tail.borrow() == target) {
        map.tail = target_prev0;
    };

    while (map.level > 1 && map.head.borrow((map.level - 1) as u64).is_none()) {
        map.level = map.level - 1;
    };

    let Node { key: _, value, nexts: _, prev: _ } = map.nodes.remove(target);
    value
}

// === Public macros ===

/// Computes the predecessor path: index `i` holds the rightmost node key at
/// level `i` whose key is strictly less than `target`, or none. Length is
/// always `max_level`.
public macro fun find_path<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $target: &$K,
    $lt: |&$K, &$K| -> bool,
): vector<Option<$K>> {
    let map = $map;
    let target = $target;
    let total_lvl = cap_level(map);
    let cur_lvl = current_level(map);

    let mut update: vector<Option<$K>> = vector[];
    let mut k: u8 = 0;
    while (k < total_lvl) {
        update.push_back(option::none());
        k = k + 1;
    };

    let mut current: Option<$K> = option::none();
    let mut i: u8 = cur_lvl;
    while (i > 0) {
        let level_idx = i - 1;
        let mut next_opt = if (current.is_some()) {
            node_next_at(map, *current.borrow(), level_idx)
        } else {
            head_at(map, level_idx)
        };
        while (next_opt.is_some()) {
            let go = $lt(next_opt.borrow(), target);
            if (go) {
                current = next_opt;
                next_opt = node_next_at(map, *next_opt.borrow(), level_idx);
            } else {
                break
            };
        };
        *update.borrow_mut(level_idx as u64) = current;
        i = i - 1;
    };
    update
}

/// Smallest-keyed node whose key is `>=` target (under the lambda). None if
/// `target` is past the largest key.
public macro fun ceiling_id<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $target: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let target = $target;
    let path = find_path!(map, target, $lt);
    let pred0 = *path.borrow(0);
    if (pred0.is_some()) {
        node_next_at(map, *pred0.borrow(), 0)
    } else {
        head_at(map, 0)
    }
}

public macro fun insert_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let new_key = $key;
    let new_value = $value;

    let path = find_path!(map, &new_key, $lt);
    let pred0 = *path.borrow(0);
    let succ0 = if (pred0.is_some()) {
        node_next_at(map, *pred0.borrow(), 0)
    } else {
        head_at(map, 0)
    };

    let mut hit_existing = false;
    if (succ0.is_some()) {
        let skey = *succ0.borrow();
        if (!$lt(&skey, &new_key) && !$lt(&new_key, &skey)) {
            hit_existing = true;
        };
    };

    if (hit_existing) {
        option::some(replace(map, *succ0.borrow(), new_value))
    } else {
        splice_new(map, new_key, new_value, path);
        option::none()
    }
}

public macro fun insert<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
): Option<$V> {
    insert_by!($map, $key, $value, |a, b| *a < *b)
}

public macro fun remove_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let target = $key;

    let path = find_path!(map, target, $lt);
    let pred0 = *path.borrow(0);
    let succ0 = if (pred0.is_some()) {
        node_next_at(map, *pred0.borrow(), 0)
    } else {
        head_at(map, 0)
    };

    let mut matched = false;
    if (succ0.is_some()) {
        let skey = *succ0.borrow();
        if (!$lt(&skey, target) && !$lt(target, &skey)) {
            matched = true;
        };
    };

    if (matched) {
        option::some(unsplice(map, path, *succ0.borrow()))
    } else {
        option::none()
    }
}

public macro fun remove<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
): Option<$V> {
    remove_by!($map, $key, |a, b| *a < *b)
}

public macro fun contains_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let map = $map;
    let target = $key;
    let succ0 = ceiling_id!(map, target, $lt);
    if (succ0.is_none()) {
        false
    } else {
        let skey = *succ0.borrow();
        !$lt(&skey, target) && !$lt(target, &skey)
    }
}

public macro fun contains<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): bool {
    contains_by!($map, $key, |a, b| *a < *b)
}

public macro fun borrow_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &$V {
    let map = $map;
    let target = $key;
    let succ0 = ceiling_id!(map, target, $lt);
    assert_key_found(succ0.is_some());
    let skey = *succ0.borrow();
    let is_equal = !$lt(&skey, target) && !$lt(target, &skey);
    assert_key_found(is_equal);
    node_value_at(map, skey)
}

public macro fun borrow<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): &$V {
    borrow_by!($map, $key, |a, b| *a < *b)
}

public macro fun borrow_mut_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &mut $V {
    let map = $map;
    let target = $key;
    let path = find_path!(map, target, $lt);
    let pred0 = *path.borrow(0);
    let succ0 = if (pred0.is_some()) {
        node_next_at(map, *pred0.borrow(), 0)
    } else {
        head_at(map, 0)
    };
    assert_key_found(succ0.is_some());
    let skey = *succ0.borrow();
    let is_equal = !$lt(&skey, target) && !$lt(target, &skey);
    assert_key_found(is_equal);
    node_value_at_mut(map, skey)
}

public macro fun borrow_mut<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
): &mut $V {
    borrow_mut_by!($map, $key, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`. `key` need not be in the map.
public macro fun next_key_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let target = $key;
    let succ0 = ceiling_id!(map, target, $lt);
    if (succ0.is_none()) {
        option::none()
    } else {
        let skey = *succ0.borrow();
        if (!$lt(&skey, target) && !$lt(target, &skey)) {
            // Equal — skip to the next-strictly-greater
            node_next_at(map, skey, 0)
        } else {
            succ0
        }
    }
}

public macro fun next_key<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    next_key_by!($map, $key, |a, b| *a < *b)
}

/// Largest key strictly less than `key`.
public macro fun prev_key_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let target = $key;
    let path = find_path!(map, target, $lt);
    *path.borrow(0)
}

public macro fun prev_key<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    prev_key_by!($map, $key, |a, b| *a < *b)
}

/// Closest key going forward. When `include == true`, returns `key` itself if
/// present (ceiling); otherwise strict-next semantics.
public macro fun find_next_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let target = $key;
    let include = $include;
    let succ0 = ceiling_id!(map, target, $lt);
    if (succ0.is_none()) {
        option::none()
    } else {
        let skey = *succ0.borrow();
        let is_equal = !$lt(&skey, target) && !$lt(target, &skey);
        if (is_equal && !include) {
            node_next_at(map, skey, 0)
        } else {
            succ0
        }
    }
}

public macro fun find_next<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_next_by!($map, $key, $include, |a, b| *a < *b)
}

/// Closest key going backward. When `include == true`, returns `key` itself
/// if present (floor); otherwise strict-previous semantics.
public macro fun find_prev_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let target = $key;
    let include = $include;
    let path = find_path!(map, target, $lt);
    let pred0 = *path.borrow(0);
    let succ0 = if (pred0.is_some()) {
        node_next_at(map, *pred0.borrow(), 0)
    } else {
        head_at(map, 0)
    };

    let mut hit: Option<$K> = option::none();
    if (include && succ0.is_some()) {
        let skey = *succ0.borrow();
        if (!$lt(&skey, target) && !$lt(target, &skey)) {
            hit = succ0;
        };
    };

    if (hit.is_some()) hit else pred0
}

public macro fun find_prev<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_prev_by!($map, $key, $include, |a, b| *a < *b)
}
