--**********
-- Frost Bites Supermarket: Interactive Tables Hands-on Lab
--**********

------------
-- Start of Lab #1: Interactive Tables
------------
-- Search and replace _xx with your UserID. ex: dba_xx --> dba_iron_man
--
-- The story: tomorrow is Durian Day, the biggest flash sale of the year at
-- the Frost Bites webstore. Thousands of shoppers will open product pages and
-- "you might also like" at the same moment. Every page needs to load fast.
--
-- In this lab you turn the webstore's two busiest queries into Interactive
-- Tables: tables built for fast, high-concurrency reads.

------------
-- 1.0 Setup
------------
use role dba_xx;
use database hol;
use schema schema_xx;
use warehouse std_wh_xx;


------------
-- 1.1 The webstore's two busiest queries
------------
-- query 1: the product page
select name, price, origin, description
from products
where product_id = 4;

-- query 2: "you might also like" for a shopper (Maya is customer 1)
select p.name, p.price, r.reason
from recommendations r
join products p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;

-- both are fast for one shopper. on Durian Day we will have thousands at once.
-- let's build tables made for that.


------------
-- 1.2 Create an Interactive Table for product pages
------------
-- an Interactive Table is defined by a query, like CREATE TABLE AS SELECT.
-- cluster by = the column your queries filter on. product pages look up by product_id.
create or replace interactive table product_page
cluster by (product_id)
as
select
    p.product_id,
    p.name,
    p.category,
    p.origin,
    p.price,
    p.description,
    coalesce(s.units_sold, 0) as units_sold_30d
from products p
left join (select product_id, sum(qty) as units_sold
           from order_items
           group by product_id) s
  on s.product_id = p.product_id;

-- notice: we used a normal warehouse (std_wh_xx) to build it.
-- you always build Interactive Tables with a normal warehouse.


------------
-- 1.3 Create an Interactive Table for recommendations
------------
-- we copy the product name and price in, so the webstore needs only one lookup.
-- recommendations are looked up by shopper, so we cluster by customer_id.
create or replace interactive table customer_recs
cluster by (customer_id)
as
select
    r.customer_id,
    r.product_id,
    p.name  as product_name,
    p.price,
    r.score,
    r.reason
from recommendations r
join products p on p.product_id = r.product_id;


------------
-- 1.4 Look at what you built
------------
show interactive tables;

describe table customer_recs;

select * from customer_recs where customer_id = 1;

------------
-- 1.5 Interactive Tables are built for reading
------------
-- TRY: change a row
update customer_recs set score = 0 where customer_id = 1;
-- ERROR: Interactive Tables do not support UPDATE or DELETE.

-- to change the data, change the source and rebuild the table.

-- update the source data 
update recommendations
set reason = reason || ' (Durian Day pick!)'
where customer_id = 1
  and reason not like '%Durian Day pick!%';

-- The interactive table still shows the old data:
select product_name, reason from customer_recs where customer_id = 1;

-- insert overwrite swaps in fresh data from the same query:
insert overwrite into customer_recs
select
    r.customer_id,
    r.product_id,
    p.name,
    p.price,
    r.score,
    r.reason
from recommendations r
join products p on p.product_id = r.product_id;

-- now the change is there
select product_name, reason from customer_recs where customer_id = 1;

-- in lab 2 you will see an Interactive Table that refreshes itself.

-- End of Lab #1.


--**********
-- Frost Bites Supermarket: Interactive Tables Hands-on Lab
--**********

------------
-- Start of Lab #2: Interactive Warehouse
------------
--
-- Interactive Tables are served by an Interactive Warehouse. It keeps your
-- tables warm in a cache so lookups come back fast, even with many
-- shoppers at once.


------------
-- 2.1 An Interactive Table that refreshes itself
------------
-- add target_lag and a warehouse, and the table keeps itself up to date.
-- target_lag = how stale the data may get (1 minute is the minimum).

create or replace interactive table top_sellers
cluster by (sale_day)
target_lag = '1 minute'
warehouse = std_wh_xx
as
select
    o.ordered_at::date as sale_day,
    oi.product_id,
    p.name             as product_name,
    sum(oi.qty)        as units_sold
from orders o
join order_items oi on oi.order_id = o.order_id
join products p     on p.product_id = oi.product_id
group by o.ordered_at::date, oi.product_id, p.name;

-- std_wh_xx refreshes top_sellers. attach it so int_wh_xx keeps it warm and serves the reads.
alter warehouse int_wh_xx add tables (top_sellers);


------------
-- 2.2 The homepage before the sale
------------
use warehouse int_wh_xx;

select product_name, units_sold
from top_sellers
where sale_day = current_date()
order by units_sold desc
limit 10;

-- where is Durian on the list? probably not at the top... yet.


------------
-- 2.3 The flash sale starts
------------
-- new orders land in the normal tables (normal warehouse writes them)
use warehouse std_wh_xx;

-- clear any earlier sale, so this step is safe to run again
delete from order_items where order_id > 900000;
delete from orders where order_id > 900000;

-- 2,000 shoppers place an order right now
insert into orders (order_id, customer_id, ordered_at, status)
select
    900000 + row_number() over (order by seq4()),
    uniform(1, 10000, random()),
    current_timestamp()::timestamp_ntz,
    'placed'
from table(generator(rowcount => 2000));

-- every one of them grabs 5 durians
insert into order_items (order_id, product_id, qty, line_total)
select o.order_id, p.product_id, 5, 5 * p.price
from orders o
join products p on p.name = 'Durian'
where o.order_id > 900000;


------------
-- 2.4 Watch the homepage catch up
------------
-- wait 1-2 minutes (the target lag), then run this again
use warehouse int_wh_xx;

select product_name, units_sold
from top_sellers
where sale_day = current_date()
order by units_sold desc
limit 10;

-- Durian jumps to #1. we did not rebuild anything.
-- the table refreshed itself within its target lag.

-- in a hurry? you can also ask for a refresh right now:
-- use warehouse std_wh_xx;
-- alter interactive table top_sellers refresh;


------------
-- 2.5 One full page load
------------
-- this is what the webstore runs when Maya opens the homepage:

-- today's top sellers
select product_name, units_sold
from top_sellers
where sale_day = current_date()
order by units_sold desc
limit 5;

-- the Durian product page
select name, price, origin, description
from product_page
where product_id = 4;

-- Maya's recommendations
select product_name, price, reason
from customer_recs
where customer_id = 1
order by score desc;



--**********
-- Frost Bites Supermarket: Interactive Tables Hands-on Lab
--**********


------------
-- Start of Lab #3: Durian Day
------------
--
-- It's Durian Day! Orders are pouring in. The webstore homepage shows
-- "Today's top sellers" and it has to keep up on its own. No pipeline, no
-- manual rebuilds.


------------
-- 3.1 Create the Interactive Warehouse
------------
-- the tables clause tells the warehouse which tables to keep warm.
create or replace interactive warehouse int_wh_xx
  tables (product_page, customer_recs)
  warehouse_size = 'xsmall';

alter warehouse int_wh_xx resume if suspended;

-- IMPORTANT: an Interactive Warehouse is meant to stay on. it only auto-suspends
-- after 24 hours idle, and each resume bills at least one hour.
-- we suspend it at the end of lab 3 (and drop it in cleanup).

-- give the cache a minute or two to warm up before you time anything.


------------
-- 3.2 It can read normal tables too
------------
use warehouse int_wh_xx;

-- query a normal table
select name, price from products where product_id = 4;
-- it works. an Interactive Warehouse can read any Snowflake table, no copy.


------------
-- 3.3 Serve the webstore from the Interactive Warehouse
------------
-- turn off the result cache so we measure real work, not a cached answer
alter session set use_cached_result = false;

-- product page
select name, price, origin, description, units_sold_30d
from product_page
where product_id = 4;

-- you might also like
select product_name, price, reason
from customer_recs
where customer_id = 1
order by score desc;

-- you can join Interactive Tables that live on the same Interactive Warehouse
select r.product_name, r.reason, p.origin, p.units_sold_30d
from customer_recs r
join product_page p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;


------------
-- 3.4 Same lookups, two warehouses
------------
-- the standard warehouse queries the source tables (products, recommendations).
-- the Interactive Warehouse queries the Interactive Tables (product_page, customer_recs).
-- query_tag labels each query so 3.5 can line up the timings.
-- each query runs twice. run 1 can include warehouse start-up or a cold cache.
-- run 2 is the fair comparison.

-- standard warehouse, source tables
use warehouse std_wh_xx;

alter session set query_tag = 'product page | standard | run 1';
select name, price, origin, description
from products
where product_id = 4;

alter session set query_tag = 'product page | standard | run 2';
select name, price, origin, description
from products
where product_id = 4;

alter session set query_tag = 'recommendations | standard | run 1';
select p.name, p.price, r.reason
from recommendations r
join products p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;

alter session set query_tag = 'recommendations | standard | run 2';
select p.name, p.price, r.reason
from recommendations r
join products p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;

-- interactive warehouse, Interactive Tables
use warehouse int_wh_xx;

alter session set query_tag = 'product page | interactive | run 1';
select name, price, origin, description, units_sold_30d
from product_page
where product_id = 4;

alter session set query_tag = 'product page | interactive | run 2';
select name, price, origin, description, units_sold_30d
from product_page
where product_id = 4;

alter session set query_tag = 'recommendations | interactive | run 1';
select product_name, price, reason
from customer_recs
where customer_id = 1
order by score desc;

alter session set query_tag = 'recommendations | interactive | run 2';
select product_name, price, reason
from customer_recs
where customer_id = 1
order by score desc;

-- clear the tag so later queries are not labeled
alter session unset query_tag;


------------
-- 3.5 Compare the timings
------------
-- compare run 2 rows. exec_ms is the warehouse's work, resume_wait_ms is
-- warehouse start-up, elapsed_ms is what the shopper waited.
select
    split_part(query_tag, ' | ', 1) as lookup,
    split_part(query_tag, ' | ', 3) as run,
    split_part(query_tag, ' | ', 2) as warehouse_type,
    warehouse_name,
    execution_time                  as exec_ms,
    queued_provisioning_time        as resume_wait_ms,
    total_elapsed_time              as elapsed_ms
from table(information_schema.query_history_by_session(result_limit => 100))
where query_tag ilike '%| run %'
  and query_type = 'SELECT'
  and execution_status ilike 'success'
  and query_text not ilike '%query_history%'
order by lookup, run, warehouse_type;

-- with one shopper the gap can be small. the real win is consistency:
-- when hundreds of shoppers hit the page together, the Interactive Warehouse
-- keeps every lookup fast instead of making them wait in line.


------------
-- 3.6 Queries must be quick
------------
-- an Interactive Warehouse gives each query 5 seconds. a fallback warehouse
-- catches anything slower, so no shopper gets an error.
alter warehouse int_wh_xx set fallback_warehouse = std_wh_xx;


-- End of Lab #3.


alter warehouse int_wh_xx suspend;
alter warehouse std_wh_xx suspend;


------------
-- 3.7 When to use what
------------
-- Snowflake Postgres:   your app already speaks Postgres. carts, checkout,
--                       inventory updates. full Postgres features.
-- Hybrid Tables:        new app, fast single-row reads and writes,
--                       all inside Snowflake.
-- Interactive Tables:   read-heavy dashboards and APIs. many users at once,
--                       fast lookups, data refreshed from Snowflake tables.

