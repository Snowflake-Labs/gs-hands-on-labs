--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #4 (Bonus): Hybrid Tables
------------
-- Run this file in a Workspaces SQL file. No search and replace needed.
-- You'll need a second SQL file for step 4.4.
--
-- The story: same store, same checkout, but this time built with Hybrid
-- Tables, inside Snowflake itself. No Postgres instance, no mirror.

------------
-- 4.0 Setup
------------
set me = (select replace(lower(current_user()), 'user_', ''));
set (role_name, wh_name, my_schema) = (select 'dba_' || $me, 'txn_wh_' || $me, 'hol.schema_' || $me);

use role identifier($role_name);
use schema identifier($my_schema);
use warehouse identifier($wh_name);


------------
-- 4.1 Create the store as Hybrid Tables
------------
create or replace hybrid table ht_products (
    product_id int primary key,
    name       varchar not null,
    price      number(8,2) not null,
    stock_qty  int not null
);

create or replace hybrid table ht_carts (
    cart_id     int primary key autoincrement start 1 increment 1,
    customer_id int not null,
    status      varchar default 'open'
);

create or replace hybrid table ht_cart_items (
    cart_id    int not null foreign key references ht_carts (cart_id),
    product_id int not null foreign key references ht_products (product_id),
    qty        int not null,
    primary key (cart_id, product_id)
);

create or replace hybrid table ht_orders (
    order_id    int primary key autoincrement start 1 increment 1,
    cart_id     int not null unique,
    customer_id int not null,
    total       number(10,2),
    ordered_at  timestamp default current_timestamp()
);

-- load the fruit aisle from the live store's catalog (the mirror)
insert into ht_products
select product_id, name, price, opening_stock
from frostbites_mirror.store.products;

-- your four ht_ tables
show hybrid tables;


------------
-- 4.2 Build your cart
------------
insert into ht_carts (customer_id) values (1);
set cart_id = (select max(cart_id) from ht_carts where customer_id = 1);

insert into ht_cart_items (cart_id, product_id, qty) values
    ($cart_id, 1, 3),
    ($cart_id, 2, 2);

-- "make it 5 dragon fruit"
-- Hybrid Tables have no ON CONFLICT. MERGE does the same job.
merge into ht_cart_items t
using (select $cart_id as cart_id, 1 as product_id, 5 as qty) s
  on t.cart_id = s.cart_id and t.product_id = s.product_id
when matched then update set qty = s.qty
when not matched then insert (cart_id, product_id, qty) values (s.cart_id, s.product_id, s.qty);

select * from ht_cart_items where cart_id = $cart_id;


------------
-- 4.3 Check out in one transaction
------------
begin;

    update ht_products p
    set stock_qty = p.stock_qty - ci.qty
    from ht_cart_items ci
    where ci.cart_id = $cart_id and ci.product_id = p.product_id;

    insert into ht_orders (cart_id, customer_id, total)
    select $cart_id, 1, sum(ci.qty * p.price)
    from ht_cart_items ci
    join ht_products p on p.product_id = ci.product_id
    where ci.cart_id = $cart_id;

    update ht_carts set status = 'checked_out' where cart_id = $cart_id;

commit;

select * from ht_orders where cart_id = $cart_id;


------------
-- 4.4 Two shoppers, the last two durians
------------
-- only 2 durians left
update ht_products set stock_qty = 2 where product_id = 4;

-- SHOPPER 1 (this file): grab one durian, but don't commit yet
begin;
update ht_products set stock_qty = stock_qty - 1 where product_id = 4;

-- the durian row is now locked by this session
show transactions;

-- SHOPPER 2: open a SECOND SQL file and run (uncomment):
--**********
-- set me = (select replace(lower(current_user()), 'user_', ''));
-- set (role_name, wh_name, my_schema) = (select 'dba_' || $me, 'txn_wh_' || $me, 'hol.schema_' || $me);
-- use role identifier($role_name);
-- use schema identifier($my_schema);
-- use warehouse identifier($wh_name);
-- update ht_products set stock_qty = stock_qty - 1 where product_id = 4;
-- (this WAITS for shopper 1)
--**********

-- back here: see shopper 2 waiting
show locks;

-- shopper 1 finishes. shopper 2's update now runs.
commit;

select name, stock_qty from ht_products where product_id = 4;
-- 0: both shoppers got one durian. no lost update, no double count.

-- a third shopper tries
update ht_products set stock_qty = stock_qty - 1 where product_id = 4;
select name, stock_qty from ht_products where product_id = 4;
-- -1! Hybrid Tables have no CHECK constraint (Postgres stopped this in lab 1).
-- here the rule goes in your SQL instead:
update ht_products set stock_qty = 0 where product_id = 4;
update ht_products set stock_qty = stock_qty - 1 where product_id = 4 and stock_qty >= 1;
-- 0 rows updated: no durian, no sale.


------------
-- 4.5 No mirror needed: join live rows with analytics tables
------------
-- Hybrid Tables live in Snowflake, so you can join them with the mirrored
-- store tables directly. Postgres needed the mirror to get here.
select o.order_id, c.name as customer, o.total, o.ordered_at
from ht_orders o
join frostbites_mirror.store.customers c on c.customer_id = o.customer_id;


------------
-- 4.6 Snowflake Postgres or Hybrid Tables?
------------
--                          Snowflake Postgres          Hybrid Tables
-- what it is               real Postgres, managed      Snowflake tables with
--                          by Snowflake                fast row reads/writes
-- best for                 apps that already speak     new apps that want to
--                          Postgres (drivers, ORMs,    stay inside Snowflake
--                          extensions)
-- upsert                   INSERT ... ON CONFLICT      MERGE
-- "no negative stock"      CHECK constraint            put the rule in your SQL
-- analytics                mirror or pg_lake to        query directly, join with
--                          Snowflake                   any Snowflake table
-- tools                    psql, any Postgres client   Workspaces, any Snowflake
--                                                      driver


------------
-- 4.7 Clean up
------------
drop table if exists ht_cart_items;
drop table if exists ht_orders;
drop table if exists ht_carts;
drop table if exists ht_products;

-- End of Lab #4.
