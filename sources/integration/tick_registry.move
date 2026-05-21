/// Concentrated-liquidity pool tick registry built on SortedMap.
///
/// Ticks are keyed by u64 index (price × 1000 to avoid floats).
/// Uses the non-`_by` uint macros — the natural fit when keys are primitives.
///
/// Demonstrates the *embedded* shape: `TickRegistry` is `has store` only and
/// wraps `SortedMap<u64, TickInfo>` as a field. Because `SortedMap` is
/// `has key, store`, the alternative — using `SortedMap<u64, TickInfo>`
/// directly as a top-level shared object — is also supported by the library;
/// the embedded shape is chosen here to show how to add domain logic around
/// the map.
module sorted_map::tick_registry;

use sorted_map::sorted_map::{Self, SortedMap};

const MAX_LEVEL: u8 = 12;
const P_INV: u64 = 4;

public struct TickInfo has copy, drop, store {
    liquidity_net: u64,
    fee_growth: u128,
}

public struct TickRegistry has store {
    ticks: SortedMap<u64, TickInfo>,
}

public fun new(ctx: &mut TxContext): TickRegistry {
    TickRegistry { ticks: sorted_map::new(MAX_LEVEL, P_INV, ctx) }
}

public fun destroy_empty(registry: TickRegistry) {
    let TickRegistry { ticks } = registry;
    ticks.destroy_empty();
}

/// Insert or overwrite a tick. Returns true if an existing entry was replaced.
public fun add_tick(
    registry: &mut TickRegistry,
    tick: u64,
    liquidity_net: u64,
    fee_growth: u128,
): bool {
    let old = sorted_map::insert!(&mut registry.ticks, tick, TickInfo { liquidity_net, fee_growth });
    old.is_some()
}

/// Remove a tick. Returns true if it existed.
public fun remove_tick(registry: &mut TickRegistry, tick: u64): bool {
    sorted_map::remove!(&mut registry.ticks, &tick).is_some()
}

public fun contains_tick(registry: &TickRegistry, tick: u64): bool {
    sorted_map::contains!(&registry.ticks, &tick)
}

public fun borrow_tick(registry: &TickRegistry, tick: u64): &TickInfo {
    sorted_map::borrow!(&registry.ticks, &tick)
}

/// Accumulate fees into a tick in-place (showcases borrow_mut!).
public fun accrue_fees(registry: &mut TickRegistry, tick: u64, delta: u128) {
    let info = sorted_map::borrow_mut!(&mut registry.ticks, &tick);
    info.fee_growth = info.fee_growth + delta;
}

/// O(1): lowest active tick.
public fun min_tick(registry: &TickRegistry): Option<u64> {
    registry.ticks.head()
}

/// O(1): highest active tick.
public fun max_tick(registry: &TickRegistry): Option<u64> {
    registry.ticks.tail()
}

/// Tick strictly above `tick` — used when the price crosses upward.
public fun tick_above(registry: &TickRegistry, tick: u64): Option<u64> {
    sorted_map::next_key!(&registry.ticks, &tick)
}

/// Tick strictly below `tick` — used when the price crosses downward.
public fun tick_below(registry: &TickRegistry, tick: u64): Option<u64> {
    sorted_map::prev_key!(&registry.ticks, &tick)
}

/// Nearest active tick at or above `target` (inclusive ceiling).
public fun ceiling_tick(registry: &TickRegistry, target: u64): Option<u64> {
    sorted_map::find_next!(&registry.ticks, &target, true)
}

/// Nearest active tick at or below `target` (inclusive floor).
public fun floor_tick(registry: &TickRegistry, target: u64): Option<u64> {
    sorted_map::find_prev!(&registry.ticks, &target, true)
}

public fun length(registry: &TickRegistry): u64 { registry.ticks.length() }
public fun is_empty(registry: &TickRegistry): bool { registry.ticks.is_empty() }
public fun liquidity_net(info: &TickInfo): u64 { info.liquidity_net }
public fun fee_growth(info: &TickInfo): u128 { info.fee_growth }
