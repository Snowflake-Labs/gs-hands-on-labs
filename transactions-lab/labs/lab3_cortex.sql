--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #3: Recommendations
------------
-- Run this file in a Workspaces SQL file. No search and replace needed.
--
-- The story: Frost Bites wants "you might also like" on the webstore.
-- The live store's sales book, which you mirrored in Lab 2, is the input.
--
-- HANDOFF CONTRACT (same columns as recommendations in the Interactive lab):
--   hol.schema_xx.recommendations (
--       customer_id   int,
--       product_id    int,
--       score         float,
--       reason        varchar,     -- shown to the shopper
--       generated_at  timestamp_ntz
--   )
--
-- INPUTS (from the mirror):
--   frostbites_mirror.store.products   -- includes flavor, texture and ways to eat per fruit
--   frostbites_mirror.store.customers
--   frostbites_mirror.store.sales      -- the store's past sales plus your own
--   @hol.public.vendor_contracts       -- four supplier contract PDFs (setup.sql section G)

------------
-- 3.0 Setup
------------
set (me, who) = (select replace(lower(current_user()), 'user_', ''), lower(current_user()));
set (role_name, wh_name, my_schema, lake_schema, lake_table) = (
    select 'dba_' || $me, 'txn_wh_' || $me, 'hol.schema_' || $me,
           'frostbites_lake.lake_' || $me, 'frostbites_lake.lake_' || $me || '.fruit_shipments');

use role identifier($role_name);
use schema identifier($my_schema);
use warehouse identifier($wh_name);

-- the sales this lab learns from: the store's past sales ('store') plus your own.
-- order ids come from one shared counter, so every order has its own number.
-- you are customer 1 in your sandbox, so your lab 1 and lab 2 checkouts are your history.
create or replace view my_sales as
select order_id as order_key, customer_id, product_id, qty
from frostbites_mirror.store.sales
where attendee in ('store', $who);

select count(*) as lines, count(distinct order_key) as orders from my_sales;
-- about 1,570 lines and 506 orders from the store, plus yours


------------
-- 3.1 Starter recommendations (no AI yet)
------------
-- a simple "bought together" baseline. 3.6 compares it with the AI version.
-- for each shopper: find their favorite fruit, then pick the 5 fruits that most
-- often share a cart with it. no taste, no contracts, no AI.
create or replace table recommendations_baseline as

-- favorites: every shopper's #1 fruit.
-- every line in the sales book is a paid sale.
-- add up how many of each fruit a shopper bought, rank them, keep the top one.
-- ex: a shopper who bought 3 lychees and 1 rambutan has lychee as their favorite.
with favorites as (
    select customer_id, product_id
    from my_sales
    group by customer_id, product_id
    qualify row_number() over (partition by customer_id order by sum(qty) desc, product_id) = 1
),

-- bought_together: which fruits end up in the same order, and how often.
-- my_sales is joined to itself so each fruit in an order gets paired with
-- every other fruit in that same order.
-- ex: an order with lychee and rambutan counts once for lychee+rambutan and once
-- for rambutan+lychee.
bought_together as (
    select a.product_id, b.product_id as also_bought_id, count(*) as times_together
    from my_sales a
    join my_sales b
      on a.order_key = b.order_key and a.product_id <> b.product_id
    group by a.product_id, b.product_id
)

-- for each shopper, the fruits most often in a cart with their favorite. keep the top 5.
-- the baseline doesn't remove fruits the shopper already bought. 3.4 does.
-- the casts match the column types in the handoff contract.
select
    f.customer_id,
    bt.also_bought_id::int                              as product_id,
    bt.times_together::float                            as score,
    'Shoppers who buy ' || p.name || ' also buy this'   as reason,
    current_timestamp()::timestamp_ntz                  as generated_at
from favorites f
join bought_together bt on bt.product_id = f.product_id
join frostbites_mirror.store.products p on p.product_id = f.product_id
qualify row_number() over (partition by f.customer_id order by bt.times_together desc) <= 5;

select * from recommendations_baseline where customer_id = 1 order by score desc;
-- your picks come from the orders you placed in labs 1 and 2. no order = no rows for you.


------------
-- 3.2 Taste: embed every fruit's flavor and texture
------------
-- one vector per fruit, built from the mirrored products table (35 embeddings).
-- ai_embed turns text into a vector: a fixed-length list of numbers that stands for
-- the meaning of the text. fruits with similar descriptions get similar vectors.
-- only flavor and texture go into the vector. ways_to_eat comes along for the 3.5 prompt.
create or replace table product_vectors as
select
    product_id,
    name,
    flavor,
    texture,
    ways_to_eat,
    ai_embed('snowflake-arctic-embed-l-v2.0',
             'Flavor: ' || flavor || '. Texture: ' || texture || '.') as taste_vec
from frostbites_mirror.store.products;

-- how alike is every pair of fruits? 1 = same taste, lower = less alike
-- joining product_vectors to itself pairs every fruit with every other fruit
-- (35 x 34 = 1,190 rows). cosine similarity compares the direction of two vectors.
create or replace table product_similarity as
select
    a.product_id,
    b.product_id                                      as similar_id,
    vector_cosine_similarity(a.taste_vec, b.taste_vec) as taste
from product_vectors a
join product_vectors b on b.product_id <> a.product_id;

-- the fruits most like Dragon Fruit
select p.name, round(s.taste, 3) as taste
from product_similarity s
join product_vectors p on p.product_id = s.similar_id
where s.product_id = 1
order by s.taste desc
limit 5;


------------
-- 3.3 Read the vendor contracts
------------
-- Frost Bites' suppliers send contracts as PDFs. look at one as text first:
-- to_file points at one file on the stage. ai_parse_document reads it and returns JSON.
-- :content is the document text. LAYOUT mode keeps headings and tables.
-- parse_json(to_varchar(...)) works whether the result comes back as a string or an object.
select parse_json(to_varchar(ai_parse_document(
           to_file('@hol.public.vendor_contracts', 'durian_kampung_emas.pdf'),
           {'mode': 'LAYOUT'}
       ))):content::string as contract_text;

-- now pull the same fields out of every contract into a table
create or replace table vendor_terms as

-- extracted: ask the AI the same 5 questions about every contract PDF.
-- directory() gives one row per file on the stage. ai_extract reads each PDF and
-- answers every question in responseFormat. x holds the answers, like this:
--   {"response": {"supplier": "...", "fruit": "...", ...}}
with extracted as (
    select
        relative_path as contract_file,
        ai_extract(
            file => to_file('@hol.public.vendor_contracts', relative_path),
            responseFormat => {
                'supplier':       'What is the name of the supplier company?',
                'fruit':          'Which fruit does this contract cover?',
                'origin':         'What is the country of origin?',
                'organic':        'Is the fruit certified organic? Answer yes or no.',
                'promo_discount': 'What promotional discount percentage is offered? Answer with a number only, or 0 if none.'
            }
        ) as x
    from directory(@hol.public.vendor_contracts)
)

-- turn each answer into a typed column. answers are always text.
-- is_organic: 'yes' becomes true, anything else false.
-- promo_pct: try_to_number returns null if the answer isn't a number. coalesce makes that 0.
select
    contract_file,
    x:response:supplier::string                                      as supplier,
    x:response:fruit::string                                         as fruit,
    x:response:origin::string                                        as origin,
    lower(x:response:organic::string) = 'yes'                        as is_organic,
    coalesce(try_to_number(x:response:promo_discount::string), 0)    as promo_pct
from extracted;

-- every contract should match a fruit in the store
-- left join keeps every contract. an empty product_id means the extracted fruit
-- name doesn't match a product name.
select v.fruit, p.product_id, v.supplier, v.is_organic, v.promo_pct
from vendor_terms v
left join product_vectors p on lower(p.name) = lower(v.fruit)
order by v.fruit;


------------
-- 3.4 Blend taste, what shoppers buy together, and promotions
------------
-- seed = each shopper's favorite fruit. no orders yet? use the top seller.
-- candidates = fruits they haven't bought.
-- score = 45% taste + 45% bought-together + 10% if the fruit is on promo.
-- each CTE below does one step. read them top to bottom.
create or replace table recommendations as

-- checked_out_items: every fruit from every paid-for order, plus who bought it.
-- everything below starts here. cart_id is the order_key from my_sales.
with checked_out_items as (
    select customer_id, order_key as cart_id, product_id, qty
    from my_sales
),

-- favorites: every shopper's #1 fruit, same idea as 3.1.
-- if two fruits tie, the lower product_id wins, so you get the same answer every run.
favorites as (
    select customer_id, product_id
    from checked_out_items
    group by customer_id, product_id
    qualify row_number() over (partition by customer_id order by sum(qty) desc, product_id) = 1
),

-- top_seller: the fruit Frost Bites sells the most of overall.
-- new shoppers who haven't ordered anything get picks based on this one.
top_seller as (
    select product_id
    from checked_out_items
    group by product_id
    order by sum(qty) desc, product_id
    limit 1
),

-- seeds: the one fruit each shopper's picks are based on.
-- starts from customers (not orders) so new shoppers get picks too.
-- has a favorite? use it. no favorite? use the top seller and set is_fallback = true.
-- top_seller is just one row, so the cross join tacks it onto every shopper.
seeds as (
    select
        c.customer_id,
        coalesce(f.product_id, t.product_id) as seed_id,
        f.product_id is null                 as is_fallback
    from frostbites_mirror.store.customers c
    cross join top_seller t
    left join favorites f on f.customer_id = c.customer_id
),

-- product_terms: which fruits are on promo, from the contracts you read in 3.3.
-- a contract is matched to a fruit by name. fruits with no contract don't show up here.
product_terms as (
    select pv.product_id, vt.promo_pct
    from product_vectors pv
    join vendor_terms vt on lower(vt.fruit) = lower(pv.name)
),

-- already_bought: every fruit each shopper has already bought.
-- candidates uses this so we don't recommend something they already have.
already_bought as (
    select distinct customer_id, product_id from checked_out_items
),

-- bought_together: which fruits end up in the same cart, same as 3.1.
-- the difference: only paid-for carts count this time.
bought_together as (
    select a.product_id, b.product_id as also_bought_id, count(*) as times_together
    from checked_out_items a
    join checked_out_items b on b.cart_id = a.cart_id and b.product_id <> a.product_id
    group by a.product_id, b.product_id
),

-- candidates: every fruit we could show a shopper, with three numbers for each:
--   taste      how close it tastes to their seed fruit (from 3.2)
--   together   how many carts had it with the seed fruit (0 if never)
--   promo_pct  its discount (0 if no promo)
-- then it removes fruits the shopper already bought. how: a left join leaves
-- ab.product_id empty when there's no match, so "where ab.product_id is null"
-- keeps only the fruits they haven't bought yet.
candidates as (
    select
        s.customer_id,
        s.seed_id,
        s.is_fallback,
        ps.similar_id                        as product_id,
        ps.taste,
        coalesce(bt.times_together, 0)       as together,
        coalesce(pt.promo_pct, 0)            as promo_pct
    from seeds s
    join product_similarity ps on ps.product_id = s.seed_id
    left join product_terms pt on pt.product_id = ps.similar_id
    left join bought_together bt
      on bt.product_id = s.seed_id and bt.also_bought_id = ps.similar_id
    left join already_bought ab
      on ab.customer_id = s.customer_id and ab.product_id = ps.similar_id
    where ab.product_id is null
),

-- scored: put taste and together on the same 0 to 1 scale for each shopper.
-- taste is a decimal like 0.62. together is a count like 12. if you added them
-- as is, the count would win every time.
-- (value - lowest) / (highest - lowest) turns the shopper's lowest candidate into 0
-- and their highest into 1.
-- if every candidate has the same value, that's dividing by zero. nullif gives an
-- empty value instead of an error, and the final select counts it as 0.
scored as (
    select
        *,
        (taste - min(taste) over (partition by customer_id))
          / nullif(max(taste) over (partition by customer_id) - min(taste) over (partition by customer_id), 0)
          as taste_n,
        (together - min(together) over (partition by customer_id))
          / nullif(max(together) over (partition by customer_id) - min(together) over (partition by customer_id), 0)
          as together_n
    from candidates
)

-- final score and reason, top 5 per shopper.
-- score: weighted sum of the rescaled signals. promo adds a flat 0.10 if there is any discount.
-- reason: fallback shoppers get a generic line. everyone else sees their favorite's name.
--         a promo adds "Now N% off". 3.5 rewrites your reasons with the LLM.
-- the join to product_vectors gets the seed fruit's name.
select
    s.customer_id,
    s.product_id::int                                                     as product_id,
    (0.45 * coalesce(s.taste_n, 0) + 0.45 * coalesce(s.together_n, 0)
       + 0.10 * iff(s.promo_pct > 0, 1, 0))::float                        as score,
    case when s.is_fallback then 'Popular with Frost Bites shoppers'
         else 'Goes well with your favorite, ' || seed.name end
      || iff(s.promo_pct > 0, '. Now ' || s.promo_pct || '% off', '')     as reason,
    current_timestamp()::timestamp_ntz                                    as generated_at
from scored s
join product_vectors seed on seed.product_id = s.seed_id
qualify row_number() over (partition by s.customer_id order by score desc, s.product_id) <= 5;

-- your picks
select p.name, round(r.score, 3) as score, r.reason
from recommendations r
join product_vectors p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;


------------
-- 3.5 Let the LLM write your reasons
------------
-- one short sentence per pick, only for you, customer 1 (5 calls).
-- frontier models need cross-region inference (setup.sql A.3).
-- if a call fails or comes back empty, the reason from 3.4 stays.
--
-- how the update works:
--   r   = your 5 rows in recommendations
--   p   = the recommended fruit (joined on p.product_id = r.product_id)
--   vt  = that fruit's vendor contract, if it has one
--   fav = one row: your favorite fruit (subquery at the bottom)
-- each of your rows gets one ai_complete call with a prompt built from those facts.
--
-- the prompt lists the facts and says "use only these facts", so the model doesn't
-- invent details. the contract line is wrapped in coalesce(..., ''): joining text
-- with || to a null gives null, so a fruit with no contract drops that line.
-- temperature 0 gives the same answer each run. max_tokens caps the reply length.
-- trim(..., '" ') removes quotes and spaces the model sometimes puts around the reply.
-- nullif(..., '') turns an empty reply into null, so coalesce keeps the reason from 3.4.
update recommendations r
set reason = coalesce(nullif(trim(ai_complete(
        'claude-sonnet-4-6',
        'Write one friendly sentence, under 25 words, recommending ' || p.name
        || ' to a shopper whose favorite fruit is ' || fav.name || '. '
        || 'Use only these facts and add nothing else. '
        || fav.name || ' flavor: ' || fav.flavor || '. '
        || fav.name || ' texture: ' || fav.texture || '. '
        || p.name || ' flavor: ' || p.flavor || '. '
        || p.name || ' texture: ' || p.texture || '. '
        || p.name || ' ways to eat: ' || p.ways_to_eat || '. '
        || coalesce(p.name || ' supplier contract: from ' || vt.origin
                    || iff(vt.is_organic, ', certified organic', '')
                    || iff(vt.promo_pct > 0, ', on promotion at ' || vt.promo_pct || '% off', '')
                    || '. If there is a promotion, mention it. ', '')
        || 'Start the sentence with the word ' || p.name || ' and end it with one way to eat it. '
        || 'Reply with the sentence only, no quotes.',
        {'temperature': 0, 'max_tokens': 120}
    ), '" '), ''), r.reason)
from product_vectors p
     left join vendor_terms vt on lower(vt.fruit) = lower(p.name),
     -- fav: your most-bought fruit, same rule as favorites in 3.4.
     -- the comma is a cross join with this one row.
     -- no sale for you means no row here, so the update changes nothing.
     (select pv.name, pv.flavor, pv.texture
      from my_sales s
      join product_vectors pv on pv.product_id = s.product_id
      where s.customer_id = 1
      group by pv.product_id, pv.name, pv.flavor, pv.texture
      qualify row_number() over (order by sum(s.qty) desc, pv.product_id) = 1) fav
where r.customer_id = 1
  and p.product_id = r.product_id;

select p.name, round(r.score, 3) as score, r.reason
from recommendations r
join product_vectors p on p.product_id = r.product_id
where r.customer_id = 1
order by r.score desc;


------------
-- 3.6 Before and after: your picks without AI and with AI
------------
-- before_ai: your picks from 3.1, numbered 1 to 5 from best score down.
-- with_ai: your picks from 3.4 and 3.5, numbered the same way.
-- the full outer join puts pick 1 next to pick 1, pick 2 next to pick 2, and so on.
-- if one list is shorter, the missing picks show up empty instead of disappearing.
with before_ai as (
    select row_number() over (order by b.score desc, b.product_id) as pick, p.name, b.reason
    from recommendations_baseline b
    join product_vectors p on p.product_id = b.product_id
    where b.customer_id = 1
),
with_ai as (
    select row_number() over (order by r.score desc, r.product_id) as pick, p.name, r.reason
    from recommendations r
    join product_vectors p on p.product_id = r.product_id
    where r.customer_id = 1
)
select
    coalesce(b.pick, a.pick) as pick,
    b.name                   as without_ai,
    b.reason                 as without_ai_reason,
    a.name                   as with_ai,
    a.reason                 as with_ai_reason
from before_ai b
full outer join with_ai a on a.pick = b.pick
order by pick;


-- End of Lab #3.
