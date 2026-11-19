--**********
-- Frost Bites Supermarket: Interactive Tables Hands-on Lab
--**********

------------
-- Start of Lab #3: Durian Day
------------
-- Search and replace _xx with your UserID. ex: dba_xx --> dba_iron_man
--
-- It's Durian Day! Orders are pouring in. The webstore homepage shows
-- "Today's top sellers" and it has to keep up on its own. No pipeline, no
-- manual rebuilds.

------------
-- 3.0 Setup
------------
use role dba_xx;
use database hol;
use schema schema_xx;
use warehouse int_wh_xx;


------------
-- 3.1 An Interactive Table that refreshes itself
------------
-- add target_lag and a warehouse, and the table keeps itself up to date.
-- target_lag = how stale the data may get (1 minute is the minimum).
create or replace interactive table top_sellers
cluster by (sale_day)
target_lag = '1 minute'
warehouse = int_wh_xx
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

-- int_wh_xx refreshes top_sellers. attach it so int_iwh_xx keeps it warm and serves the reads.
alter warehouse int_iwh_xx add tables (hol.schema_xx.top_sellers);


------------
-- 3.2 The homepage before the sale
------------
use warehouse int_iwh_xx;

select product_name, units_sold
from top_sellers
where sale_day = current_date()
order by units_sold desc
limit 10;

-- where is Durian on the list? probably not at the top... yet.


------------
-- 3.3 The flash sale starts
------------
-- new orders land in the normal tables (normal warehouse writes them)
use warehouse int_wh_xx;

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
-- 3.4 Watch the homepage catch up
------------
-- wait 1-2 minutes (the target lag), then run this again
use warehouse int_iwh_xx;

select product_name, units_sold
from top_sellers
where sale_day = current_date()
order by units_sold desc
limit 10;

-- Durian jumps to #1. we did not rebuild anything.
-- the table refreshed itself within its target lag.

-- in a hurry? you can also ask for a refresh right now:
-- alter interactive table top_sellers refresh;


------------
-- 3.5 One full page load
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


------------
-- 3.6 When to use what
------------
-- Snowflake Postgres:   your app already speaks Postgres. carts, checkout,
--                       inventory updates. full Postgres features.
-- Hybrid Tables:        new app, fast single-row reads and writes,
--                       all inside Snowflake.
-- Interactive Tables:   read-heavy dashboards and APIs. many users at once,
--                       fast lookups, data refreshed from Snowflake tables.


------------
-- 3.7 Suspend the Interactive Warehouse
------------
-- it only auto-suspends after 24 hours idle, so suspend it when you are done
alter warehouse int_iwh_xx suspend;

-- End of Lab #3. Run cleanup.sql when you are finished.
