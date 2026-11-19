--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #1: Your Sandbox, Your First Order
------------
-- No search and replace needed in this lab.
--
-- Run this file in psql (your terminal), NOT in Workspaces.
-- Paste ONE step at a time and check the result under it before you go on.
--
-- The story: you are a developer at Frost Bites, an online exotic-fruit store that
-- runs on Snowflake Postgres. You have two places to work:
--   your sandbox   a private copy of the shop, named like your login (user_xx).
--                  "products" means your sandbox's shelf.
--   the live store a shared schema called "store". "store.products" is the store's
--                  catalog. store.sales is the store's sales book.
-- You build and test the checkout in your sandbox, shopping as yourself (customer 1).
-- Each checkout also files its sale lines in the store's sales book.

------------
-- 1.0 Connect
------------
-- Connect with psql using the command from the prerequisites doc your instructor shared.
-- You should see the postgres=> prompt.

-- your sandbox tables
\dt
-- expect 5 tables: cart_items, carts, customers, orders, products

-- the live store's tables
\dt store.*
-- expect 3 tables: customers, products, sales


------------
-- 1.1 Meet the shop
------------
-- the exotic fruit aisle
select product_id, name, origin, price, stock_qty
from products
order by product_id;
-- expect 35 fruits

-- you are the shopper: customer 1
select * from customers where customer_id = 1;
-- expect your name, for example Iron Man


------------
-- 1.2 Guard rails: the database keeps the shop honest
------------
-- TRY: negative stock
update products set stock_qty = -5 where name = 'Star Fruit';
-- ERROR: violates check constraint. you can't have -5 star fruit.

-- TRY: an item in a cart that doesn't exist
insert into cart_items (cart_id, product_id, qty) values (999, 1, 1);
-- ERROR: violates foreign key constraint. no phantom carts.

-- TRY: a second account with your email
insert into customers (name, email) select 'Copycat', email from customers where customer_id = 1;
-- ERROR: violates unique constraint. one account per email.


------------
-- 1.3 Build your cart
------------
-- your sandbox starts empty, so your first cart is cart 1
insert into carts (customer_id) values (1);

-- 3 dragon fruit, 2 rambutan, 4 star fruit
insert into cart_items (cart_id, product_id, qty) values
    (1, 1, 3),
    (1, 2, 2),
    (1, 27, 4);

-- look at the cart
select p.name, ci.qty, p.price, ci.qty * p.price as line_total
from cart_items ci
join products p on p.product_id = ci.product_id
where ci.cart_id = 1;
-- expect 3 lines


------------
-- 1.4 UPSERT: "actually, make it 5 dragon fruit"
------------
-- insert the row, and if it's already in the cart, update it instead
insert into cart_items (cart_id, product_id, qty) values (1, 1, 5)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

-- run it again: no error, same result. safe to retry.
insert into cart_items (cart_id, product_id, qty) values (1, 1, 5)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

-- the same statement adds a new fruit (mangosteen) when it's not in the cart
insert into cart_items (cart_id, product_id, qty) values (1, 3, 1)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

select p.name, ci.qty
from cart_items ci
join products p on p.product_id = ci.product_id
where ci.cart_id = 1;
-- expect 4 lines: dragon fruit 5, rambutan 2, mangosteen 1, star fruit 4


------------
-- 1.5 Check out the risky way (no transaction)
------------
-- stock before
select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);
-- expect 120, 90, 40, 140

-- step 1: take the fruit off the shelf
update products p
set stock_qty = p.stock_qty - ci.qty
from cart_items ci
where ci.cart_id = 1 and ci.product_id = p.product_id;

-- IMAGINE: the app crashes right here. the order is never written.

select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);
-- expect 115, 88, 39, 136

select count(*) from orders where cart_id = 1;
select count(*) from store.sales where attendee = current_user;
-- both 0. the fruit is gone, but there is no order and no sale. the fruit vanished.

-- put the fruit back before we continue
update products p
set stock_qty = p.stock_qty + ci.qty
from cart_items ci
where ci.cart_id = 1 and ci.product_id = p.product_id;


------------
-- 1.6 Check out the safe way (one transaction)
------------
-- everything between begin and commit happens together, or not at all
begin;

    -- take the fruit off the shelf
    update products p
    set stock_qty = p.stock_qty - ci.qty
    from cart_items ci
    where ci.cart_id = 1 and ci.product_id = p.product_id;

    -- place the order
    insert into orders (cart_id, customer_id, total)
    select 1, 1, sum(ci.qty * p.price)
    from cart_items ci
    join products p on p.product_id = ci.product_id
    where ci.cart_id = 1;

    -- close the cart
    update carts set status = 'checked_out' where cart_id = 1;

    -- file the sale lines in the live store's sales book
    insert into store.sales (order_id, customer_id, customer, product_id, fruit, qty, price, line_total)
    select o.order_id, o.customer_id, c.name, ci.product_id, p.name, ci.qty, p.price, ci.qty * p.price
    from orders o
    join customers c   on c.customer_id = o.customer_id
    join cart_items ci on ci.cart_id = o.cart_id
    join products p    on p.product_id = ci.product_id
    where o.cart_id = 1;

commit;

select * from orders where cart_id = 1;
-- expect one order, total 78.88. its order_id is the next number from the store's shared
-- counter, so it goes up as the class orders and never repeats.

select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);
-- expect 115, 88, 39, 136

select attendee, order_id, customer, fruit, qty, line_total from store.sales where attendee = current_user;
-- expect 4 lines with the same order_id. the attendee column is your login, filled in
-- automatically, and the customer is you.
-- order placed, stock updated and sale filed, together.


------------
-- 1.7 All or nothing: someone tries to buy 999 durians
------------
insert into carts (customer_id) values (1);
-- this is cart 2

insert into cart_items (cart_id, product_id, qty) values (2, 4, 999);

select name, stock_qty from products where product_id = 4;
-- expect 15

begin;

    update products p
    set stock_qty = p.stock_qty - ci.qty
    from cart_items ci
    where ci.cart_id = 2 and ci.product_id = p.product_id;
    -- ERROR: violates check constraint. there are not 999 durians.

    insert into orders (cart_id, customer_id, total) values (2, 1, 0);
    -- ERROR: current transaction is aborted. nothing else can run.

rollback;

select name, stock_qty from products where product_id = 4;
-- expect 15 again. no half-finished order.

select count(*) from store.sales where attendee = current_user;
-- expect 4. the sales book did not change either.

update carts set status = 'abandoned' where cart_id = 2;


------------
-- 1.8 The sales book is append-only
------------
-- the live store keeps its history. you can add sales but never change them.
update store.sales set qty = 99;
-- ERROR: permission denied

delete from store.sales;
-- ERROR: permission denied

-- and you can't sign a sale with someone else's name
insert into store.sales (attendee, order_id, customer_id, customer, product_id, fruit, qty, price, line_total)
values ('someone_else', 1, 1, 'x', 1, 'x', 1, 1, 1);
-- ERROR: permission denied


------------
-- 1.9 Recap
------------
select c.cart_id, c.status, o.order_id, o.total, o.ordered_at
from carts c
left join orders o on o.cart_id = c.cart_id
where c.customer_id = 1
order by c.cart_id;
-- expect cart 1 checked_out with your order, cart 2 abandoned

-- you used:
--   constraints  -> bad data can't get in
--   UPSERT       -> add or update a cart line in one statement
--   transactions -> stock, order and sale change together, or not at all
--   permissions  -> the sales book only grows
--
-- keep this psql window open. you need it in lab 2.
