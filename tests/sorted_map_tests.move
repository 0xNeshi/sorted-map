#[test_only]
module sorted_map::sorted_map_tests;

use std::unit_test::assert_eq;
use sorted_map::sorted_map::{Self, SortedMap};

const SEED: u64 = 42;
const MAX_LEVEL: u8 = 16;
const P_INV: u64 = 4;

// === Test helpers ===
//
// Wrap each macro in a regular function so test bodies don't accumulate
// per-call locals from macro expansion. Move's bytecode caps locals per
// function at 255; multiple macro calls in one test blew past that.

fun new_map(): SortedMap<u64, u64> {
    let ctx = &mut tx_context::dummy();
    sorted_map::new<u64, u64>(SEED, MAX_LEVEL, P_INV, ctx)
}

fun ins(map: &mut SortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    map.insert!(k, v)
}

fun rem(map: &mut SortedMap<u64, u64>, k: u64): Option<u64> {
    map.remove!(&k)
}

fun has(map: &SortedMap<u64, u64>, k: u64): bool {
    map.contains!(&k)
}

fun get(map: &SortedMap<u64, u64>, k: u64): u64 {
    *map.borrow!(&k)
}

fun set(map: &mut SortedMap<u64, u64>, k: u64, v: u64) {
    let r = map.borrow_mut!(&k);
    *r = v;
}

fun nxt(map: &SortedMap<u64, u64>, k: u64): Option<u64> {
    map.next_key!(&k)
}

fun prv(map: &SortedMap<u64, u64>, k: u64): Option<u64> {
    map.prev_key!(&k)
}

fun find_n(map: &SortedMap<u64, u64>, k: u64, include: bool): Option<u64> {
    map.find_next!(&k, include)
}

fun find_p(map: &SortedMap<u64, u64>, k: u64, include: bool): Option<u64> {
    map.find_prev!(&k, include)
}

fun fill(map: &mut SortedMap<u64, u64>, xs: vector<u64>) {
    let mut i = 0;
    while (i < xs.length()) {
        let k = *xs.borrow(i);
        ins(map, k, k * 10);
        i = i + 1;
    }
}

fun drain(map: &mut SortedMap<u64, u64>, xs: vector<u64>) {
    let mut i = 0;
    while (i < xs.length()) {
        let k = *xs.borrow(i);
        let _ = rem(map, k);
        i = i + 1;
    }
}

fun consume(map: SortedMap<u64, u64>) {
    sorted_map::destroy_empty(map);
}

// === Lifecycle ===

#[test]
fun new_is_empty() {
    let map = new_map();
    assert_eq!(map.length(), 0);
    assert!(map.is_empty());
    assert!(map.head().is_none());
    assert!(map.tail().is_none());
    consume(map);
}

#[test]
#[expected_failure(abort_code = 0)]
fun new_rejects_zero_max_level() {
    let ctx = &mut tx_context::dummy();
    let map = sorted_map::new<u64, u64>(0, 0, 4, ctx);
    consume(map);
}

#[test]
#[expected_failure(abort_code = 1)]
fun new_rejects_p_inv_below_two() {
    let ctx = &mut tx_context::dummy();
    let map = sorted_map::new<u64, u64>(0, 8, 1, ctx);
    consume(map);
}

#[test]
#[expected_failure(abort_code = 3)]
fun destroy_empty_aborts_when_non_empty() {
    let mut map = new_map();
    ins(&mut map, 1, 100);
    consume(map);
}

// === Single-element flow ===

#[test]
fun insert_then_remove() {
    let mut map = new_map();
    let prev = ins(&mut map, 1, 100);
    assert!(prev.is_none());
    assert_eq!(map.length(), 1);

    let removed = rem(&mut map, 1);
    assert!(removed.is_some());
    assert_eq!(*removed.borrow(), 100);
    assert!(map.is_empty());
    consume(map);
}

#[test]
fun insert_overwrite_returns_previous() {
    let mut map = new_map();
    let p1 = ins(&mut map, 7, 70);
    assert!(p1.is_none());

    let p2 = ins(&mut map, 7, 700);
    assert!(p2.is_some());
    assert_eq!(*p2.borrow(), 70);
    assert_eq!(map.length(), 1);

    drain(&mut map, vector[7]);
    consume(map);
}

#[test]
fun remove_absent_returns_none() {
    let mut map = new_map();
    ins(&mut map, 1, 10);
    let r = rem(&mut map, 999);
    assert!(r.is_none());
    assert_eq!(map.length(), 1);
    drain(&mut map, vector[1]);
    consume(map);
}

// === Multi-element ordering ===

#[test]
fun multiple_inserts_track_head_and_tail() {
    let mut map = new_map();
    let xs = vector[5u64, 2, 9, 1, 7, 3, 8, 6, 4, 10];
    fill(&mut map, xs);
    assert_eq!(map.length(), 10);

    assert_eq!(*map.head().borrow(), 1);
    assert_eq!(get(&map, 1), 10);
    assert_eq!(*map.tail().borrow(), 10);
    assert_eq!(get(&map, 10), 100);

    drain(&mut map, xs);
    consume(map);
}

#[test]
fun ascending_traversal_via_next_key() {
    let mut map = new_map();
    let xs = vector[50u64, 20, 30, 10, 40];
    fill(&mut map, xs);

    let mut got: vector<u64> = vector[];
    let mut cursor = map.head();
    while (cursor.is_some()) {
        let k = *cursor.borrow();
        got.push_back(k);
        cursor = nxt(&map, k);
    };
    assert_eq!(got, vector[10, 20, 30, 40, 50]);

    drain(&mut map, xs);
    consume(map);
}

#[test]
fun descending_traversal_via_prev_key() {
    let mut map = new_map();
    let xs = vector[50u64, 20, 30, 10, 40];
    fill(&mut map, xs);

    let mut got: vector<u64> = vector[];
    let mut cursor = map.tail();
    while (cursor.is_some()) {
        let k = *cursor.borrow();
        got.push_back(k);
        cursor = prv(&map, k);
    };
    assert_eq!(got, vector[50, 40, 30, 20, 10]);

    drain(&mut map, xs);
    consume(map);
}

// === Contains / borrow / borrow_mut ===

#[test]
fun contains_present_and_absent() {
    let mut map = new_map();
    fill(&mut map, vector[1, 2, 3]);
    assert!(has(&map, 2));
    assert!(!has(&map, 999));
    drain(&mut map, vector[1, 2, 3]);
    consume(map);
}

#[test]
fun borrow_returns_value() {
    let mut map = new_map();
    fill(&mut map, vector[1, 2]);
    assert_eq!(get(&map, 2), 20);
    drain(&mut map, vector[1, 2]);
    consume(map);
}

#[test]
#[expected_failure(abort_code = 2)]
fun borrow_aborts_when_missing() {
    let mut map = new_map();
    ins(&mut map, 1, 10);
    let _ = get(&map, 999);
    drain(&mut map, vector[1]);
    consume(map);
}

#[test]
fun borrow_mut_updates_value() {
    let mut map = new_map();
    ins(&mut map, 5, 50);
    set(&mut map, 5, 555);
    assert_eq!(get(&map, 5), 555);
    drain(&mut map, vector[5]);
    consume(map);
}

// === next_key / prev_key edge cases ===

#[test]
fun next_and_prev_key_at_boundaries() {
    let mut map = new_map();
    fill(&mut map, vector[10, 20, 30]);

    assert_eq!(*nxt(&map, 5).borrow(), 10);
    assert!(nxt(&map, 30).is_none());

    assert_eq!(*prv(&map, 999).borrow(), 30);
    assert!(prv(&map, 10).is_none());

    // Strict-next/strict-prev when target is in map
    assert_eq!(*nxt(&map, 20).borrow(), 30);
    assert_eq!(*prv(&map, 20).borrow(), 10);

    drain(&mut map, vector[10, 20, 30]);
    consume(map);
}

// === find_next / find_prev with include flag ===

#[test]
fun find_next_include_returns_self_when_present() {
    let mut map = new_map();
    fill(&mut map, vector[10, 20, 30]);

    assert_eq!(*find_n(&map, 20, true).borrow(), 20);
    assert_eq!(*find_n(&map, 20, false).borrow(), 30);
    assert_eq!(*find_n(&map, 15, true).borrow(), 20);
    assert!(find_n(&map, 999, true).is_none());

    drain(&mut map, vector[10, 20, 30]);
    consume(map);
}

#[test]
fun find_prev_include_returns_self_when_present() {
    let mut map = new_map();
    fill(&mut map, vector[10, 20, 30]);

    assert_eq!(*find_p(&map, 20, true).borrow(), 20);
    assert_eq!(*find_p(&map, 20, false).borrow(), 10);
    assert_eq!(*find_p(&map, 25, true).borrow(), 20);
    assert!(find_p(&map, 5, true).is_none());

    drain(&mut map, vector[10, 20, 30]);
    consume(map);
}

// === remove preserves ordering ===

#[test]
fun remove_middle_preserves_order() {
    let mut map = new_map();
    fill(&mut map, vector[10, 20, 30, 40, 50]);

    let r = rem(&mut map, 30);
    assert!(r.is_some());
    assert_eq!(*r.borrow(), 300);
    assert_eq!(map.length(), 4);

    assert_eq!(*nxt(&map, 20).borrow(), 40);
    assert_eq!(*prv(&map, 40).borrow(), 20);
    assert!(!has(&map, 30));

    drain(&mut map, vector[10, 20, 40, 50]);
    consume(map);
}

#[test]
fun remove_head_and_tail_updates_endpoints() {
    let mut map = new_map();
    fill(&mut map, vector[10, 20, 30]);

    let _ = rem(&mut map, 10);
    assert_eq!(*map.head().borrow(), 20);

    let _ = rem(&mut map, 30);
    assert_eq!(*map.tail().borrow(), 20);

    let _ = rem(&mut map, 20);
    assert!(map.is_empty());
    consume(map);
}

// === Bulk insert + sorted traversal ===

#[test]
fun bulk_insert_traverses_sorted() {
    let mut map = new_map();
    let xs = vector[
        17u64, 4, 23, 8, 14, 1, 27, 12, 19, 6,
        29, 0, 21, 10, 25, 3, 16, 7, 28, 2,
        13, 22, 9, 18, 5, 26, 11, 24, 15, 20,
    ];
    fill(&mut map, xs);
    assert_eq!(map.length(), 30);

    let mut expected: u64 = 0;
    let mut cursor = map.head();
    while (cursor.is_some()) {
        let k = *cursor.borrow();
        assert_eq!(k, expected);
        assert_eq!(get(&map, k), expected * 10);
        expected = expected + 1;
        cursor = nxt(&map, k);
    };
    assert_eq!(expected, 30);

    drain(&mut map, xs);
    consume(map);
}

// === Custom comparator (_by variants) ===

fun ins_desc(map: &mut SortedMap<u64, u64>, k: u64, v: u64) {
    let _ = map.insert_by!(k, v, |a, b| *a > *b);
}

fun rem_desc(map: &mut SortedMap<u64, u64>, k: u64) {
    let _ = map.remove_by!(&k, |a, b| *a > *b);
}

fun nxt_desc(map: &SortedMap<u64, u64>, k: u64): Option<u64> {
    map.next_key_by!(&k, |a, b| *a > *b)
}

#[test]
fun reverse_comparator_sorts_descending() {
    let ctx = &mut tx_context::dummy();
    let mut map = sorted_map::new<u64, u64>(SEED, MAX_LEVEL, P_INV, ctx);
    let xs = vector[5u64, 2, 9, 1, 7];
    let mut i = 0;
    while (i < xs.length()) {
        let k = *xs.borrow(i);
        ins_desc(&mut map, k, k * 10);
        i = i + 1;
    };

    // Under reverse order, the "smallest" key is the largest number (9).
    assert_eq!(*map.head().borrow(), 9);
    assert_eq!(*map.tail().borrow(), 1);

    let mut got: vector<u64> = vector[];
    let mut cursor = map.head();
    while (cursor.is_some()) {
        let k = *cursor.borrow();
        got.push_back(k);
        cursor = nxt_desc(&map, k);
    };
    assert_eq!(got, vector[9, 7, 5, 2, 1]);

    let mut i = 0;
    while (i < xs.length()) {
        rem_desc(&mut map, *xs.borrow(i));
        i = i + 1;
    };
    sorted_map::destroy_empty(map);
}

// === Composite key with custom comparator ===

fun fill_lex(map: &mut SortedMap<vector<u64>, u64>, items: vector<vector<u64>>) {
    let mut i = 0;
    while (i < items.length()) {
        let k = *items.borrow(i);
        map.insert_by!(k, i, |a, b| {
            if (*a.borrow(0) != *b.borrow(0)) *a.borrow(0) < *b.borrow(0)
            else *a.borrow(1) < *b.borrow(1)
        });
        i = i + 1;
    }
}

fun drain_lex(map: &mut SortedMap<vector<u64>, u64>, items: vector<vector<u64>>) {
    let mut i = 0;
    while (i < items.length()) {
        let k = *items.borrow(i);
        let _ = map.remove_by!(&k, |a, b| {
            if (*a.borrow(0) != *b.borrow(0)) *a.borrow(0) < *b.borrow(0)
            else *a.borrow(1) < *b.borrow(1)
        });
        i = i + 1;
    }
}

#[test]
fun composite_key_sorts_lexicographically() {
    let ctx = &mut tx_context::dummy();
    let mut map = sorted_map::new<vector<u64>, u64>(SEED, MAX_LEVEL, P_INV, ctx);

    let items = vector[
        vector[2u64, 5],
        vector[1u64, 9],
        vector[2u64, 1],
        vector[1u64, 4],
    ];
    fill_lex(&mut map, items);

    // Smallest is (1, 4)
    let mk = *map.head().borrow();
    assert_eq!(*mk.borrow(0), 1);
    assert_eq!(*mk.borrow(1), 4);

    // Largest is (2, 5)
    let xk = *map.tail().borrow();
    assert_eq!(*xk.borrow(0), 2);
    assert_eq!(*xk.borrow(1), 5);

    drain_lex(&mut map, items);
    sorted_map::destroy_empty(map);
}

// === metadata ===

#[test]
fun metadata_reflects_state() {
    let mut map = new_map();
    fill(&mut map, vector[1, 2, 3]);

    let m = map.metadata();
    assert_eq!(m.metadata_length(), 3);
    assert_eq!(m.metadata_max_level(), MAX_LEVEL);
    assert_eq!(m.metadata_p_inv(), P_INV);
    assert!(m.metadata_level() >= 1);
    assert!(m.metadata_level() <= MAX_LEVEL);

    drain(&mut map, vector[1, 2, 3]);
    consume(map);
}
