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
use warehouse int_wh_xx;


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

-- notice: we used a normal warehouse (int_wh_xx) to build it.
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

-- in lab 3 you will see an Interactive Table that refreshes itself.

-- End of Lab #1. Move on to lab2.sql.
