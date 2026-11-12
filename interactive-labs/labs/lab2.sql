--**********
-- Frost Bites Supermarket: Interactive Tables Hands-on Lab
--**********

------------
-- Start of Lab #2: Interactive Warehouse
------------
-- Search and replace _xx with your UserID. ex: dba_xx --> dba_iron_man
--
-- Interactive Tables are served by an Interactive Warehouse. It keeps your
-- tables warm in a cache so lookups come back fast, even with many
-- shoppers at once.

------------
-- 2.0 Setup
------------
use role dba_xx;
use database hol;
use schema schema_xx;
use warehouse int_wh_xx;


------------
-- 2.1 Create the Interactive Warehouse
------------
-- the tables clause tells the warehouse which tables to keep warm.
create or replace interactive warehouse int_iwh_xx
  tables (hol.schema_xx.product_page, hol.schema_xx.customer_recs)
  warehouse_size = 'xsmall';

alter warehouse int_iwh_xx resume if suspended;

-- IMPORTANT: an Interactive Warehouse is meant to stay on. it only auto-suspends
-- after 24 hours idle, and each resume bills at least one hour.
-- we suspend it at the end of lab 3 (and drop it in cleanup).

-- give the cache a minute or two to warm up before you time anything.


------------
-- 2.2 It can read normal tables too
------------
use warehouse int_iwh_xx;

-- query a normal table
select name, price from products where product_id = 4;
-- it works. an Interactive Warehouse can read any Snowflake table, no copy.
-- the speed comes from Interactive Tables: they are the ones kept warm.


------------
-- 2.3 Serve the webstore from the Interactive Warehouse
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
-- 2.4 Same lookups, two warehouses
------------
-- the standard warehouse queries the source tables (products, recommendations).
-- the Interactive Warehouse queries the Interactive Tables (product_page, customer_recs).
-- query_tag labels each query so 2.5 can line up the timings.
-- each query runs twice. run 1 can include warehouse start-up or a cold cache.
-- run 2 is the fair comparison.

-- standard warehouse, source tables
use warehouse int_wh_xx;

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
use warehouse int_iwh_xx;

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
-- 2.5 Compare the timings
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
-- 2.6 Queries must be quick
------------
-- an Interactive Warehouse gives each query 5 seconds. a fallback warehouse
-- catches anything slower, so no shopper gets an error.
alter warehouse int_iwh_xx set fallback_warehouse = int_wh_xx;

-- End of Lab #2. Move on to lab3.sql.
