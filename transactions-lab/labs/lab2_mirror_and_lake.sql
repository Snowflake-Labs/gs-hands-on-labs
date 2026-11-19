--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #2: Postgres to Snowflake
------------
-- Run this file in a Workspaces SQL file (Projects > Workspaces).
-- Steps marked [psql] go in the psql terminal from Lab 1.
-- The only thing to replace is lake_xx in step 2.6 (one place, in psql).
--
-- The story: the store manager wants a daily report: top fruits, sales by hour,
-- what's running low. Every checkout files its sale lines in the live store's sales
-- book, in Postgres. You'll get the store into Snowflake two ways, with no ETL:
--   Part A  Data Mirroring  - the sales book and the catalog, copied continuously
--   Part B  pg_lake         - an Iceberg table you create yourself in Postgres

------------
-- 2.0 Setup
------------
-- your Snowflake user name matches your Postgres login (user_iron_man), so the
-- steps below find your rows by themselves.
set (me, who) = (select replace(lower(current_user()), 'user_', ''), lower(current_user()));
set (role_name, wh_name, my_schema, lake_schema, lake_table) = (
    select 'dba_' || $me, 'txn_wh_' || $me, 'hol.schema_' || $me,
           'frostbites_lake.lake_' || $me, 'frostbites_lake.lake_' || $me || '.fruit_shipments');

use role identifier($role_name);
use warehouse identifier($wh_name);

select $who as you;
-- expect your login, for example user_iron_man


------------------------------------------------------------
-- PART A: Data Mirroring
------------------------------------------------------------

------------
-- 2.1 What the mirror built
------------
-- the instructor mirrored the three tables of the live store:
-- store.products (the catalog), store.customers (the shoppers) and store.sales (the sales book)
show schemas in database frostbites_mirror;
show tables in schema frostbites_mirror.store;
show views in schema frostbites_mirror.store;

-- for every Postgres table you get three objects:
--   sales            the copy, updated every minute
--   sales$live       the copy + changes not applied yet (~30 seconds behind)
--   sales$changes    every insert, update and delete for the last 7 days

-- the store's whole sales book, and your part of it
select count(*) as all_lines from frostbites_mirror.store.sales;
select count(*) as your_lines from frostbites_mirror.store.sales where attendee = $who;
-- your_lines: 4, the lines from your lab 1 checkout (it can take a minute to show up)
-- [psql] compare:  select count(*) from store.sales where attendee = current_user;


------------
-- 2.2 Watch a checkout land in Snowflake
------------
-- your sales right now
select attendee, order_id, fruit, qty, line_total
from frostbites_mirror.store.sales$live
where attendee = $who
order by line_id;
-- expect 4 lines (your first order)

-- [psql] you buy 2 more mangosteen. copy this block into psql:
/*
begin;
  insert into carts (customer_id, status) values (1, 'checked_out');
  insert into cart_items (cart_id, product_id, qty) values (3, 3, 2);
  update products set stock_qty = stock_qty - 2 where product_id = 3;
  insert into orders (cart_id, customer_id, total)
    select 3, 1, 2 * price from products where product_id = 3;
  insert into store.sales (order_id, customer_id, customer, product_id, fruit, qty, price, line_total)
    select o.order_id, o.customer_id, c.name, ci.product_id, p.name, ci.qty, p.price, ci.qty * p.price
    from orders o
    join customers c   on c.customer_id = o.customer_id
    join cart_items ci on ci.cart_id = o.cart_id
    join products p    on p.product_id = ci.product_id
    where o.cart_id = 3;
commit;
*/

-- wait about 30 seconds, then run this again
select attendee, order_id, fruit, qty, line_total
from frostbites_mirror.store.sales$live
where attendee = $who
order by line_id;
-- expect 5 lines: your second order is there. the new sale came across.

-- the copy itself catches up on the next refresh (every minute)
select count(*) as your_lines_in_the_copy
from frostbites_mirror.store.sales
where attendee = $who;
-- 4 for up to a minute, then 5


------------
-- 2.3 The change feed
------------
-- every change to your sales, oldest first.
--   _change_type: S = starting snapshot, I = insert, D = delete
--   the sales book is append-only, so you only see S and I: no updates, no deletes
select _commit_time, _change_type, order_id, fruit, qty
from frostbites_mirror.store.sales$changes
where attendee = $who
order by _commit_time, order_id, fruit;

-- this feed is open Iceberg, so you could build pipelines or audits on it.


------------
-- 2.4 All or nothing, even in Snowflake
------------
-- an order's lines arrive together, because the mirror applies each Postgres
-- transaction as one unit. you never see half an order.
-- (query the copy, not $live, when you need this guarantee)
select order_id, count(*) as lines, sum(line_total) as total
from frostbites_mirror.store.sales
where attendee = $who
group by order_id
order by order_id;
-- expect your first order: 4 lines, 78.88 and your second: 1 line, 25.98
-- $live  = freshest (~30 seconds)
-- copy   = consistent (refreshed every minute)


------------
-- 2.5 The live shelf
------------
-- the whole class shops from one shelf. stock left = opening stock minus
-- everything the class has sold since the lab started (store history is not counted).
select p.name,
       p.opening_stock,
       coalesce(sum(s.qty), 0)                        as sold_by_class,
       p.opening_stock - coalesce(sum(s.qty), 0)      as stock_left
from frostbites_mirror.store.products p
left join frostbites_mirror.store.sales$live s
       on s.product_id = p.product_id and s.attendee <> 'store'
group by p.name, p.opening_stock
order by stock_left
limit 10;
-- Durian is at the top: the store only has 40 for the whole class.
-- run it again after your neighbour checks out: the numbers drop.
-- the shelf is worked out in Snowflake, so there is no CHECK rule here:
-- if the class buys too much, stock_left goes below zero.


------------------------------------------------------------
-- PART B: pg_lake by hand
------------------------------------------------------------

------------
-- 2.6 [psql] Create an Iceberg table in Postgres
------------
-- suppliers send shipment notices. we keep them in an Iceberg table:
-- open, columnar files, written straight from Postgres.
-- replace lake_xx with your lake schema, for example lake_iron_man, then copy into psql:
/*
create table lake_xx.fruit_shipments (
    shipment_id int,
    product_id  int,
    qty         int,
    supplier    text,
    arrives_on  date
) using iceberg;

insert into lake_xx.fruit_shipments values
    (1, 4,  40, 'Kuala Lumpur Growers', current_date + 1),
    (2, 1, 120, 'Mekong Farms',         current_date + 1),
    (3, 3,  60, 'Bali Orchards',        current_date + 2),
    (4, 2,  80, 'Chiang Mai Co-op',     current_date + 2),
    (5, 5,  30, 'Kerala Fruit Co',      current_date + 3);

select * from lake_xx.fruit_shipments;
*/

-- it's a real Postgres table: you can query it, join it, insert into it.
-- the difference is how it's stored: Iceberg instead of Postgres rows.


------------
-- 2.7 Find it in Snowflake
------------
-- FROSTBITES_LAKE is linked to Postgres. new Iceberg tables show up on their
-- own in about 30 seconds. no CREATE statement needed in Snowflake.
-- (ignore the snowflake_cdc_logs schema: that's the mirror's bookkeeping)
show schemas in database frostbites_lake;
show tables in schema identifier($lake_schema);

select * from identifier($lake_table);
-- expect 5 rows

-- Postgres wrote the files. Snowflake reads the same files. no copy.


------------
-- 2.8 Mirroring or pg_lake?
------------
-- Data Mirroring: copy your existing app tables, every change, automatically.
-- pg_lake:        choose to write some tables as Iceberg from the start
--                 (logs, events, shipments), shared with Snowflake as-is.


------------------------------------------------------------
-- REPORT: the store manager's dashboard
------------------------------------------------------------

------------
-- 2.9 Top 10 fruits by units sold
------------
select fruit, sum(qty) as units_sold
from frostbites_mirror.store.sales
group by fruit
order by units_sold desc
limit 10;

------------
-- 2.10 Sales by hour of day
------------
select hour(ordered_at)    as hour_of_day,
       sum(qty)            as units,
       sum(line_total)     as revenue
from frostbites_mirror.store.sales
group by hour_of_day
order by hour_of_day;

------------
-- 2.10b Make it a materialized view
------------
-- 2.10 scans every sale each time you run it. a materialized view stores the
-- hourly totals and Snowflake keeps them current as the mirror table changes.
-- it reads the mirror table, not sales$live, so it is as fresh as the mirror table
-- (up to the refresh interval behind a commit).
-- materialized views need Enterprise edition.
use schema identifier($my_schema);

create or replace materialized view sales_by_hour as
select hour(ordered_at)    as hour_of_day,
       sum(qty)            as units,
       sum(line_total)     as revenue
from frostbites_mirror.store.sales
group by hour(ordered_at);

-- a materialized view cannot have ORDER BY, so sort when you query it
select * from sales_by_hour order by hour_of_day;

-- 2.9 and 2.11 cannot be materialized views. 2.9 is fine to run live, and 2.11 joins
-- tables and reads sales$live, which is a view.

-- NOTE: this view depends on a table the mirror owns.
-- if the mirror table is dropped, renamed or swapped, the view is suspended and
-- queries on it fail. adding a column does not suspend it. it is not dropped for you.
-- check:  show materialized views;   (see invalid and invalid_reason)
-- fix:    rebuild it. copy grants keeps who can read it.
--   create or replace materialized view sales_by_hour copy grants as ...

------------
-- 2.11 Running low? Stock vs incoming shipments
------------
-- the live shelf from the mirror + your shipments from pg_lake, in one query
select p.name,
       p.opening_stock - coalesce(sold.units, 0) as stock_left,
       coalesce(sum(sh.qty), 0)                  as arriving_soon
from frostbites_mirror.store.products p
left join (select product_id, sum(qty) as units
           from frostbites_mirror.store.sales$live
           where attendee <> 'store'
           group by product_id) sold
       on sold.product_id = p.product_id
left join identifier($lake_table) sh
       on sh.product_id = p.product_id
group by p.name, p.opening_stock, sold.units
order by stock_left
limit 10;

------------
-- 2.12 Pin it to a dashboard
------------
-- Projects > Dashboards > + Dashboard, name it "Frost Bites Daily".
-- add a tile for each query above:
--   2.5   bar chart  (name, stock_left): the live shelf
--   2.9   bar chart  (fruit, units_sold)
--   2.10b line chart (hour_of_day, units), reads the materialized view
--   2.11  table
-- the tiles read the mirror, so they stay current as Postgres changes.

-- End of Lab #2.
