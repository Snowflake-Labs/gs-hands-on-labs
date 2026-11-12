--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #2: Postgres to Snowflake
------------
-- Search and replace _xx with your UserID. ex: dba_xx --> dba_iron_man
--
-- Run this file in a Workspaces SQL file (Projects > Workspaces).
-- Steps marked [psql] go in your psql terminal from Lab 1.
--
-- The story: the store manager wants a daily report: top fruits, orders by
-- hour, what's running low. The data lives in Postgres. You'll get it into
-- Snowflake two ways, with no ETL:
--   Part A  Data Mirroring  - the app tables, copied continuously
--   Part B  pg_lake         - an Iceberg table you create yourself in Postgres

------------
-- 2.0 Setup
------------
use role dba_xx;
use warehouse txn_wh_xx;

-- BACKUP PATH: if your instructor says mirroring isn't available, replace
-- frostbites_mirror.schema_xx with hol.frostbites_backup everywhere below,
-- use products instead of products$live, and skip steps 2.2-2.4.


------------------------------------------------------------
-- PART A: Data Mirroring
------------------------------------------------------------

------------
-- 2.1 What the mirror built
------------
-- your Postgres schema_xx shows up as a schema in FROSTBITES_MIRROR
show schemas in database frostbites_mirror;

-- for every Postgres table you get three objects:
--   orders           the copy, updated every minute
--   orders$live      the copy + changes not applied yet (~30 seconds behind)
--   orders$changes   every insert, update and delete for the last 7 days
show tables in schema frostbites_mirror.schema_xx;
show views in schema frostbites_mirror.schema_xx;

-- same row counts as Postgres
select count(*) from frostbites_mirror.schema_xx.orders;
select count(*) from frostbites_mirror.schema_xx.cart_items;
-- [psql] compare:  select count(*) from orders;


------------
-- 2.2 Watch a checkout land in Snowflake
------------
-- mangosteen stock right now
select product_id, name, stock_qty
from frostbites_mirror.schema_xx.products$live
where product_id = 3;

-- [psql] Maya buys 2 mangosteen. copy this block into psql:
-- (new psql window? run  set search_path to schema_xx;  first)
/*
begin;
  insert into carts (customer_id, status) values (1, 'checked_out') returning cart_id \gset
  insert into cart_items (cart_id, product_id, qty) values (:cart_id, 3, 2);
  update products set stock_qty = stock_qty - 2 where product_id = 3;
  insert into orders (cart_id, customer_id, total)
    select :cart_id, 1, 2 * price from products where product_id = 3;
commit;
*/

-- wait about 30 seconds, then run this again
select product_id, name, stock_qty
from frostbites_mirror.schema_xx.products$live
where product_id = 3;
-- stock went down by 2. the UPDATE came across, not just new rows.

-- the copy itself catches up on the next refresh (every minute)
select product_id, name, stock_qty
from frostbites_mirror.schema_xx.products
where product_id = 3;


------------
-- 2.3 The change feed
------------
-- every change to mangosteen, oldest first.
--   _change_type: S = starting snapshot, I = insert, D = delete
--   an update shows up as a D + I pair with _is_update = true
--   (the D row only carries the key, so stock_qty is empty there)
select _commit_time, _change_type, _is_update, stock_qty
from frostbites_mirror.schema_xx.products$changes
where product_id = 3
order by _commit_time, _change_type;

-- look closely: you can see lab 1 in here. the risky checkout took a
-- mangosteen (40 -> 39), you put it back (39 -> 40), then the real
-- checkout took it again (40 -> 39), and just now Maya bought 2 (39 -> 37).
-- this feed is open Iceberg, so you could build pipelines or audits on it.


------------
-- 2.4 All or nothing, even in Snowflake
------------
-- Maya's latest order and its cart line arrive together, because the mirror
-- applies each Postgres transaction as one unit.
-- (query the copy, not $live, when you need this guarantee)
select o.order_id, o.total, o.ordered_at, ci.product_id, ci.qty
from frostbites_mirror.schema_xx.orders o
join frostbites_mirror.schema_xx.cart_items ci on ci.cart_id = o.cart_id
where o.customer_id = 1
order by o.order_id desc;
-- $live  = freshest (~30 seconds)
-- copy   = consistent (refreshed every minute)


------------------------------------------------------------
-- PART B: pg_lake by hand
------------------------------------------------------------

------------
-- 2.5 [psql] Create an Iceberg table in Postgres
------------
-- suppliers send shipment notices. we keep them in an Iceberg table:
-- open, columnar files, written straight from Postgres. copy into psql:
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
-- 2.6 Find it in Snowflake
------------
-- FROSTBITES_LAKE is linked to Postgres. new Iceberg tables show up on their
-- own in about 30 seconds. no CREATE statement needed in Snowflake.
-- (ignore the snowflake_cdc_logs schema: that's the mirror's bookkeeping)
show schemas in database frostbites_lake;
show tables in schema frostbites_lake.lake_xx;

select * from frostbites_lake.lake_xx.fruit_shipments;

-- Postgres wrote the files. Snowflake reads the same files. no copy.


------------
-- 2.7 Mirroring or pg_lake?
------------
-- Data Mirroring: copy your existing app tables, every change, automatically.
-- pg_lake:        choose to write some tables as Iceberg from the start
--                 (logs, events, shipments), shared with Snowflake as-is.


------------------------------------------------------------
-- REPORT: the store manager's dashboard
------------------------------------------------------------

------------
-- 2.8 Top 10 fruits by units sold
------------
select p.name, sum(ci.qty) as units_sold
from frostbites_mirror.schema_xx.orders o
join frostbites_mirror.schema_xx.cart_items ci on ci.cart_id = o.cart_id
join frostbites_mirror.schema_xx.products p on p.product_id = ci.product_id
group by p.name
order by units_sold desc
limit 10;

------------
-- 2.9 Orders and revenue by hour of day
------------
select hour(ordered_at) as hour_of_day,
       count(*)         as orders,
       sum(total)       as revenue
from frostbites_mirror.schema_xx.orders
group by hour_of_day
order by hour_of_day;

------------
-- 2.9b Make it a materialized view
------------
-- 2.9 scans every order each time you run it. a materialized view stores the
-- hourly totals and Snowflake keeps them current as the mirror table changes.
-- it reads the mirror table, not orders$live, so it is as fresh as the mirror table
-- (up to the refresh interval behind a commit).
-- materialized views need Enterprise edition.
create or replace materialized view hol.schema_xx.orders_by_hour as
select hour(ordered_at) as hour_of_day,
       count(*)         as orders,
       sum(total)       as revenue
from frostbites_mirror.schema_xx.orders
group by hour(ordered_at);

-- a materialized view cannot have ORDER BY, so sort when you query it
select * from hol.schema_xx.orders_by_hour order by hour_of_day;

-- 2.8 and 2.10 cannot be materialized views. they join tables, and a materialized
-- view reads one table. 2.10 also reads orders$live, which is a view.

-- NOTE: this view depends on a table the mirror owns.
-- the mirror applies Postgres column changes to the mirror table on its own.
-- if an existing column is changed, dropped or renamed, or the table (or its schema or
-- database) is dropped, renamed or swapped, the view is suspended and queries on it
-- fail. this holds even for a column the view does not use. adding a column does not
-- suspend it. it is not dropped for you.
-- check:  show materialized views;   (see invalid and invalid_reason)
-- fix:    rebuild it. copy grants keeps who can read it. the definition must still
--         be valid against the new columns.
--   create or replace materialized view hol.schema_xx.orders_by_hour copy grants as ...

------------
-- 2.10 Running low? Stock vs incoming shipments
------------
-- live stock from the mirror + shipments from pg_lake, in one query
select p.name,
       p.stock_qty,
       coalesce(sum(s.qty), 0) as arriving_soon
from frostbites_mirror.schema_xx.products$live p
left join frostbites_lake.lake_xx.fruit_shipments s on s.product_id = p.product_id
group by p.name, p.stock_qty
order by p.stock_qty
limit 10;

------------
-- 2.11 Pin it to a dashboard
------------
-- Projects > Dashboards > + Dashboard, name it "Frost Bites Daily".
-- add a tile for each query above:
--   2.8  bar chart  (name, units_sold)
--   2.9b line chart (hour_of_day, orders), reads the materialized view
--   2.10 table
-- the tiles read the mirror, so they stay current as Postgres changes.

-- End of Lab #2.
