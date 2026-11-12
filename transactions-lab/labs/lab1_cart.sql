--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #1: Build a Cart, Place an Order
------------
-- Search and replace _xx with your UserID. ex: schema_xx --> schema_iron_man
--
-- Run this file in psql (your terminal), NOT in Workspaces.
-- Copy and run one step at a time.
--
-- The story: Maya opens the Frost Bites webstore, fills her cart with exotic
-- fruit and checks out. Behind the webstore is plain Postgres, running on
-- Snowflake.

  -- 1.0 Connect
  ------------
  -- in your terminal. your instructor shares the host, and psql prompts you to log in.
  --   export PGSSLMODE=require
  --   psql -h <host> -p 5432 -d postgres -U user_xx


set search_path to schema_xx;

-- see the store's tables
\dt


------------
-- 1.1 Meet the store
------------
-- the exotic fruit aisle
select product_id, name, origin, price, stock_qty
from products
order by product_id;

-- our shopper
select * from customers where customer_id = 1;


------------
-- 1.2 Guard rails: the database keeps the store honest
------------
-- TRY: negative stock
update products set stock_qty = -5 where name = 'Star Fruit';
-- ERROR: violates check constraint. you can't have -5 star fruit.

-- TRY: a fruit that doesn't exist
insert into cart_items (cart_id, product_id, qty) values (1, 999, 1);
-- ERROR: violates foreign key constraint. no phantom fruit.

-- TRY: a second account with Maya's email
insert into customers (name, email) values ('Maya Again', 'maya@frostbites.example');
-- ERROR: violates unique constraint. one account per email.


------------
-- 1.3 Build Maya's cart
------------
-- create a cart and keep its id in a psql variable (\gset)
insert into carts (customer_id) values (1) returning cart_id \gset
\echo :cart_id

-- 3 dragon fruit, 2 rambutan, 4 star fruit
insert into cart_items (cart_id, product_id, qty) values
    (:cart_id, 1, 3),
    (:cart_id, 2, 2),
    (:cart_id, 27, 4);

-- look at the cart
select p.name, ci.qty, p.price, ci.qty * p.price as line_total
from cart_items ci
join products p on p.product_id = ci.product_id
where ci.cart_id = :cart_id;


------------
-- 1.4 UPSERT: "actually, make it 5 dragon fruit"
------------
-- insert the row, and if it's already in the cart, update it instead
insert into cart_items (cart_id, product_id, qty) values (:cart_id, 1, 5)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

-- run it again: no error, same result. safe to retry.
insert into cart_items (cart_id, product_id, qty) values (:cart_id, 1, 5)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

-- the same statement adds a new fruit (mangosteen) when it's not in the cart
insert into cart_items (cart_id, product_id, qty) values (:cart_id, 3, 1)
on conflict (cart_id, product_id) do update set qty = excluded.qty;

select p.name, ci.qty
from cart_items ci
join products p on p.product_id = ci.product_id
where ci.cart_id = :cart_id;


------------
-- 1.5 Check out the risky way (no transaction)
------------
-- stock before
select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);

-- step 1: take the fruit off the shelf
update products p
set stock_qty = p.stock_qty - ci.qty
from cart_items ci
where ci.cart_id = :cart_id and ci.product_id = p.product_id;

-- IMAGINE: the app crashes right here. the order is never written.

select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);
select count(*) from orders where cart_id = :cart_id;
-- stock is gone, but there is no order. the fruit vanished.

-- put the fruit back before we continue
update products p
set stock_qty = p.stock_qty + ci.qty
from cart_items ci
where ci.cart_id = :cart_id and ci.product_id = p.product_id;


------------
-- 1.6 Check out the safe way (one transaction)
------------
-- everything between begin and commit happens together, or not at all
begin;

    -- take the fruit off the shelf
    update products p
    set stock_qty = p.stock_qty - ci.qty
    from cart_items ci
    where ci.cart_id = :cart_id and ci.product_id = p.product_id;

    -- place the order
    insert into orders (cart_id, customer_id, total)
    select :cart_id, 1, sum(ci.qty * p.price)
    from cart_items ci
    join products p on p.product_id = ci.product_id
    where ci.cart_id = :cart_id;

    -- close the cart
    update carts set status = 'checked_out' where cart_id = :cart_id;

commit;

select * from orders where cart_id = :cart_id;
select product_id, name, stock_qty from products where product_id in (1, 2, 3, 27);
-- order placed and stock updated, together.


------------
-- 1.7 All or nothing: someone tries to buy 999 durians
------------
insert into carts (customer_id) values (1) returning cart_id as big_cart \gset
insert into cart_items (cart_id, product_id, qty) values (:big_cart, 4, 999);

select name, stock_qty from products where product_id = 4;

begin;

    update products p
    set stock_qty = p.stock_qty - ci.qty
    from cart_items ci
    where ci.cart_id = :big_cart and ci.product_id = p.product_id;
    -- ERROR: violates check constraint. there are not 999 durians.

    insert into orders (cart_id, customer_id, total) values (:big_cart, 1, 0);
    -- ERROR: current transaction is aborted. nothing else can run.

rollback;

select name, stock_qty from products where product_id = 4;
-- unchanged. no half-finished order.

update carts set status = 'abandoned' where cart_id = :big_cart;


------------
-- 1.8 Recap
------------
select c.cart_id, c.status, o.order_id, o.total, o.ordered_at
from carts c
left join orders o on o.cart_id = c.cart_id
where c.customer_id = 1
order by c.cart_id;

-- you used:
--   constraints  -> bad data can't get in
--   UPSERT       -> add or update a cart line in one statement
--   transactions -> stock and order change together, or not at all
--
-- keep this psql window open. you need it in lab 2.
