/// Ask-side order book built on SortedMap with a composite struct key.
///
/// `OrderKey { price, seq }` sorts price-ascending then seq-ascending (FIFO
/// within a price level). The struct key is why the `_by` macros are needed —
/// there is no built-in `<` on a struct, so a comparator lambda is supplied
/// at every call site.
module sorted_map::order_book;

use sorted_map::sorted_map::{Self, SortedMap};

const MAX_LEVEL: u8 = 12;
const P_INV: u64 = 4;

public struct OrderKey has copy, drop, store {
    price: u64,
    seq: u64,
}

public struct Order has copy, drop, store {
    amount: u64,
    maker: address,
}

public struct OrderBook has store {
    orders: SortedMap<OrderKey, Order>,
    next_seq: u64,
}

/// Canonical total order: price-ascending, seq-ascending within same price.
fun lt(a: &OrderKey, b: &OrderKey): bool {
    a.price < b.price || (a.price == b.price && a.seq < b.seq)
}

public fun new(ctx: &mut TxContext): OrderBook {
    OrderBook { orders: sorted_map::new(MAX_LEVEL, P_INV, ctx), next_seq: 0 }
}

public fun destroy_empty(book: OrderBook) {
    let OrderBook { orders, next_seq: _ } = book;
    orders.destroy_empty();
}

/// Place an ask order. Returns the `OrderKey` required for cancellation.
public fun place(book: &mut OrderBook, price: u64, amount: u64, maker: address): OrderKey {
    let key = OrderKey { price, seq: book.next_seq };
    book.next_seq = book.next_seq + 1;
    sorted_map::insert_by!(&mut book.orders, key, Order { amount, maker }, |a, b| lt(a, b));
    key
}

/// Cancel an order. Returns true if it existed.
public fun cancel(book: &mut OrderBook, key: &OrderKey): bool {
    sorted_map::remove_by!(&mut book.orders, key, |a, b| lt(a, b)).is_some()
}

/// Reduce an order's amount in-place (partial fill; showcases borrow_mut_by!).
public fun reduce_amount(book: &mut OrderBook, key: &OrderKey, by: u64) {
    let order = sorted_map::borrow_mut_by!(&mut book.orders, key, |a, b| lt(a, b));
    order.amount = order.amount - by;
}

/// Key of the best (lowest-priced) ask, or none if the book is empty.
public fun best_ask_key(book: &OrderBook): Option<OrderKey> {
    book.orders.head()
}

/// Data of the best ask order, or none if empty.
public fun best_ask(book: &OrderBook): Option<Order> {
    let key_opt = book.orders.head();
    if (key_opt.is_none()) return option::none();
    let key = *key_opt.borrow();
    option::some(*sorted_map::borrow_by!(&book.orders, &key, |a, b| lt(a, b)))
}

/// Next order key strictly after `key` in sorted order.
public fun next_order(book: &OrderBook, key: &OrderKey): Option<OrderKey> {
    sorted_map::next_key_by!(&book.orders, key, |a, b| lt(a, b))
}

/// Key of the first order at or above `price` (inclusive ceiling).
/// Returns none if all orders are below `price`.
public fun first_at_or_above(book: &OrderBook, price: u64): Option<OrderKey> {
    // seq=0 is the smallest possible seq, so this target is <= any real order
    // at this price, making find_next! with include=true behave as a ceiling.
    let target = OrderKey { price, seq: 0 };
    sorted_map::find_next_by!(&book.orders, &target, true, |a, b| lt(a, b))
}

public fun contains(book: &OrderBook, key: &OrderKey): bool {
    sorted_map::contains_by!(&book.orders, key, |a, b| lt(a, b))
}

public fun borrow_order(book: &OrderBook, key: &OrderKey): &Order {
    sorted_map::borrow_by!(&book.orders, key, |a, b| lt(a, b))
}

public fun length(book: &OrderBook): u64 { book.orders.length() }
public fun is_empty(book: &OrderBook): bool { book.orders.is_empty() }
public fun key_price(key: &OrderKey): u64 { key.price }
public fun key_seq(key: &OrderKey): u64 { key.seq }
public fun order_amount(order: &Order): u64 { order.amount }
public fun order_maker(order: &Order): address { order.maker }
