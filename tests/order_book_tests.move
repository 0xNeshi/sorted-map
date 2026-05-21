#[test_only]
module sorted_map::order_book_tests;

use sorted_map::order_book;
use sorted_map::sorted_map::EKeyNotFound;

/// Full order-book lifecycle: place orders at mixed prices and same-price FIFO,
/// verify best ask, iterate, find by price, reduce amount, cancel.
#[test]
fun test_order_book_lifecycle() {
    let mut ctx = tx_context::dummy();
    let mut book = order_book::new(&mut ctx);
    let alice: address = @0xA;
    let bob: address = @0xB;

    // Place at prices 300, 100, 200 out of order; two orders at price 100 (FIFO)
    let k300 = order_book::place(&mut book, 300, 30, alice);
    let k100a = order_book::place(&mut book, 100, 10, alice); // seq 1
    let k200 = order_book::place(&mut book, 200, 20, bob);
    let k100b = order_book::place(&mut book, 100, 11, bob); // seq 3 (same price, later)

    // Best ask is lowest price; within that price, first-placed order comes first
    assert!(order_book::best_ask_key(&book) == option::some(k100a));
    assert!(order_book::order_maker(order_book::best_ask(&book).borrow()) == alice);

    // FIFO within the 100-price level: k100a → k100b → k200 → k300
    assert!(order_book::next_order(&book, &k100a) == option::some(k100b));
    assert!(order_book::next_order(&book, &k100b) == option::some(k200));
    assert!(order_book::next_order(&book, &k200) == option::some(k300));
    assert!(order_book::next_order(&book, &k300).is_none());

    // first_at_or_above: exact match, between prices, below all, above all
    assert!(order_book::first_at_or_above(&book, 200) == option::some(k200));
    assert!(order_book::first_at_or_above(&book, 150) == option::some(k200));
    assert!(order_book::first_at_or_above(&book, 50) == option::some(k100a));
    assert!(order_book::first_at_or_above(&book, 999).is_none());

    // Partial fill via borrow_mut_by!
    order_book::reduce_amount(&mut book, &k300, 5);
    assert!(order_book::order_amount(order_book::borrow_order(&book, &k300)) == 25);

    // Cancel removes from the map
    let was_there = order_book::cancel(&mut book, &k100a);
    assert!(was_there);
    assert!(!order_book::contains(&book, &k100a));
    // After cancelling k100a, best ask advances to k100b
    assert!(order_book::best_ask_key(&book) == option::some(k100b));

    order_book::cancel(&mut book, &k100b);
    order_book::cancel(&mut book, &k200);
    order_book::cancel(&mut book, &k300);
    order_book::destroy_empty(book);
}

/// Borrowing a cancelled order aborts with EKeyNotFound (code 2).
#[test]
#[expected_failure(abort_code = EKeyNotFound, location = sorted_map::order_book)]
fun test_borrow_cancelled_order_aborts() {
    let mut ctx = tx_context::dummy();
    let mut book = order_book::new(&mut ctx);
    let alice: address = @0xA;

    let key = order_book::place(&mut book, 100, 1000, alice);
    order_book::cancel(&mut book, &key);
    order_book::borrow_order(&book, &key); // gone → abort
    order_book::destroy_empty(book); // unreachable; satisfies type checker
}
