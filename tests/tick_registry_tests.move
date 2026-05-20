#[test_only]
module sorted_map::tick_registry_tests;

use sorted_map::tick_registry;

/// Full pool lifecycle: insert ticks out of order, verify sorted min/max,
/// walk neighbors, ceiling/floor, mutate fees in-place, then drain.
#[test]
fun test_tick_pool_lifecycle() {
    let mut ctx = tx_context::dummy();
    let mut registry = tick_registry::new(&mut ctx);

    // Insert ticks intentionally out of order
    tick_registry::add_tick(&mut registry, 3000, 300, 0);
    tick_registry::add_tick(&mut registry, 1000, 100, 0);
    tick_registry::add_tick(&mut registry, 2000, 200, 0);

    // Sorted extremes
    assert!(tick_registry::min_tick(&registry) == option::some(1000));
    assert!(tick_registry::max_tick(&registry) == option::some(3000));

    // Upward tick-crossing traversal from 1000
    assert!(tick_registry::tick_above(&registry, 1000) == option::some(2000));
    assert!(tick_registry::tick_above(&registry, 2000) == option::some(3000));
    assert!(tick_registry::tick_above(&registry, 3000).is_none());

    // Downward traversal from 3000
    assert!(tick_registry::tick_below(&registry, 3000) == option::some(2000));
    assert!(tick_registry::tick_below(&registry, 1000).is_none());

    // Ceiling and floor with a price that sits between two active ticks
    assert!(tick_registry::ceiling_tick(&registry, 1500) == option::some(2000));
    assert!(tick_registry::floor_tick(&registry, 1500) == option::some(1000));

    // Exact-match: ceiling and floor both return the tick itself
    assert!(tick_registry::ceiling_tick(&registry, 2000) == option::some(2000));
    assert!(tick_registry::floor_tick(&registry, 2000) == option::some(2000));

    // Accumulate fees in-place via borrow_mut!, then read back via borrow!
    tick_registry::accrue_fees(&mut registry, 1000, 50);
    let info = tick_registry::borrow_tick(&registry, 1000);
    assert!(tick_registry::fee_growth(info) == 50);

    // Re-insert same key replaces the value
    let replaced = tick_registry::add_tick(&mut registry, 1000, 999, 999);
    assert!(replaced);
    assert!(tick_registry::liquidity_net(tick_registry::borrow_tick(&registry, 1000)) == 999);

    // Clean up
    tick_registry::remove_tick(&mut registry, 1000);
    tick_registry::remove_tick(&mut registry, 2000);
    tick_registry::remove_tick(&mut registry, 3000);
    tick_registry::destroy_empty(registry);
}

/// Borrowing a tick that was never inserted aborts with EKeyNotFound (code 2).
#[test]
#[
    expected_failure(
        abort_code = sorted_map::sorted_map::EKeyNotFound,
        location = sorted_map::tick_registry,
    ),
]
fun test_borrow_absent_tick_aborts() {
    let mut ctx = tx_context::dummy();
    let registry = tick_registry::new(&mut ctx);
    tick_registry::borrow_tick(&registry, 9999);
    tick_registry::destroy_empty(registry); // unreachable; satisfies type checker
}
