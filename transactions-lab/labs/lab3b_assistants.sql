--**********
-- Frost Bites Supermarket: Snowflake Postgres Hands-on Lab
--**********

------------
-- Start of Lab #3B: Store and shopper assistants (optional)
------------
-- Run this file in a Workspaces SQL file, after Lab 3. No search and replace needed.
--
-- The story: two people ask Frost Bites questions in plain English.
--   the store manager sees the whole store: sales, stock, suppliers, recommendations.
--   you, as a shopper (customer 1), see only your own picks, purchases and fruit facts.
--
-- You build one assistant (a Cortex Agent) for each. The point of this lab:
-- an agent can only show what its caller's role can read. Roles and secure
-- views set each person's scope, not the prompt.
--
--   role dba_xx         -> store_manager_assistant -> frostbites_sv + contract_search
--   role storefront_xx  -> shopper_assistant       -> shopper_sv -> secure views only
--
-- INPUTS:
--   frostbites_mirror.store.products, store.sales   -- the live store, mirrored in Lab 2
--   recommendations, vendor_terms                    -- built in Lab 3, in your schema
--   @hol.public.vendor_contracts                     -- the contract PDFs (setup.sql G)

------------
-- 3.0 Setup
------------
set me = (select replace(lower(current_user()), 'user_', ''));
set (role_name, sf_role, wh_name, my_schema) = (
    select 'dba_' || $me, 'storefront_' || $me, 'txn_wh_' || $me, 'hol.schema_' || $me);

use role identifier($role_name);
use schema identifier($my_schema);
use warehouse identifier($wh_name);


------------
-- 3.7 A semantic view of the whole store
------------
-- a semantic view tells Cortex Analyst what the tables mean: which columns are
-- names to group by (dimensions), which are numbers to add up (metrics), and
-- how the tables join. Analyst turns a question into SQL against it.
--
-- two logical tables are queries instead of tables:
--   stock:          what's left on the shelf. opening stock minus what the class sold,
--                   the same rule as the live shelf in Lab 2.5.
--   supplier_terms: the contract terms from Lab 3.3, matched to products by name.
-- sales is the store's sales book: one row per fruit per order, every row a paid sale.
create or replace semantic view frostbites_sv
  tables (
    products as frostbites_mirror.store.products primary key (product_id)
      with synonyms ('fruits') comment = 'The fruits Frost Bites sells, with shelf price',
    sales as frostbites_mirror.store.sales primary key (line_id)
      comment = 'The sales book: one row per fruit per order. Every row is a paid sale',
    stock as (
        select p.product_id, p.opening_stock,
               p.opening_stock - coalesce(sum(iff(s.attendee <> 'store', s.qty, 0)), 0) as stock_left
        from frostbites_mirror.store.products p
        left join frostbites_mirror.store.sales s on s.product_id = p.product_id
        group by p.product_id, p.opening_stock
    ) primary key (product_id)
      comment = 'Stock left on the shelf: opening stock minus what the class sold',
    customers as frostbites_mirror.store.customers primary key (customer_id)
      comment = 'Webstore shoppers. Customer 1 is you',
    supplier_terms as (
        select p.product_id, vt.supplier, vt.origin, vt.is_organic, vt.promo_pct
        from vendor_terms vt
        join frostbites_mirror.store.products p on lower(p.name) = lower(vt.fruit)
    ) primary key (product_id)
      comment = 'Supplier contract terms, one row per fruit that has a contract',
    recommendations as recommendations primary key (customer_id, product_id)
      comment = 'The 5 fruits recommended to each shopper, with the reason shown to them'
  )
  relationships (
    sales (product_id) references products,
    stock (product_id) references products,
    supplier_terms (product_id) references products,
    recommendations (product_id) references products,
    recommendations (customer_id) references customers
  )
  dimensions (
    products.fruit as products.name with synonyms ('fruit name', 'product'),
    products.category as products.category,
    products.price as products.price comment = 'Shelf price per fruit in USD',
    sales.order_day as sales.ordered_at::date,
    sales.order_hour as hour(sales.ordered_at) comment = 'Hour of the day, 0 to 23',
    sales.buyer as sales.customer comment = 'Name of the shopper on the sale',
    stock.stock_left as stock.stock_left with synonyms ('stock', 'inventory', 'on hand'),
    customers.recommended_to as customers.name,
    supplier_terms.supplier as supplier_terms.supplier,
    supplier_terms.supplier_country as supplier_terms.origin,
    supplier_terms.is_organic as supplier_terms.is_organic,
    supplier_terms.promo_pct as supplier_terms.promo_pct comment = 'Promotional discount in percent, 0 if none',
    recommendations.reason as recommendations.reason,
    recommendations.score as recommendations.score
  )
  metrics (
    sales.units_sold as sum(sales.qty),
    sales.revenue as sum(sales.line_total),
    sales.order_count as count(distinct sales.order_id),
    stock.total_stock_left as sum(stock.stock_left)
  )
  comment = 'Frost Bites store: sales, stock, suppliers and recommendations';

-- query it yourself first. this is the kind of SQL Analyst writes for you.
select * from semantic_view(frostbites_sv
    dimensions products.fruit
    metrics sales.units_sold)
order by units_sold desc
limit 5;


------------
-- 3.8 Search the full contract text
------------
-- Lab 3.3 pulled 5 fields out of each contract. the manager also asks about
-- things we didn't extract: price per kg, weekly volume, delivery days, signers.
-- store the full text, then build a Cortex Search service over it.
-- parse_json(to_varchar(...)) works whether the result comes back as a string or an object.
create or replace table contract_text as
select
    relative_path as contract_file,
    parse_json(to_varchar(ai_parse_document(
        to_file('@hol.public.vendor_contracts', relative_path),
        {'mode': 'LAYOUT'}
    ))):content::string as contract_text
from directory(@hol.public.vendor_contracts);

select contract_file, left(contract_text, 80) as starts_with from contract_text;

-- with_warehouse(): some statements need the warehouse name spelled out.
-- with_warehouse() puts your warehouse where the statement says {WAREHOUSE}, then runs it.
-- execute as caller: it runs with the role of whoever calls it.
create or replace procedure with_warehouse(stmt varchar)
returns varchar
language sql
execute as caller
as
$$
begin
  let ddl varchar := replace(stmt, '{WAREHOUSE}', current_warehouse());
  execute immediate :ddl;
  return 'done, using ' || current_warehouse();
end;
$$;

-- the search service indexes contract_text and keeps it fresh within target_lag.
-- note: a search service runs with its owner's rights. anyone with USAGE on it
-- can search everything it indexed.
call with_warehouse($$
create or replace cortex search service contract_search
  on contract_text
  attributes contract_file
  warehouse = {WAREHOUSE}
  target_lag = '1 day'
  as select contract_file, contract_text from contract_text
$$);

-- ask it something. results come back best match first.
select parse_json(snowflake.cortex.search_preview(
    $my_schema || '.contract_search',
    '{"query": "durian price per kg and weekly volume", "columns": ["contract_file"], "limit": 2}'
)):results as results;


------------
-- 3.9 The store manager's assistant
------------
-- a Cortex Agent picks a tool for each question, runs it, and writes the answer.
-- two more helpers first. both run as caller, like with_warehouse().
--
-- make_agent(): an agent spec must spell out the warehouse its tools run on.
-- make_agent() puts your warehouse where the spec says {WAREHOUSE}, then creates the agent.
create or replace procedure make_agent(agent_name varchar, spec varchar)
returns varchar
language sql
execute as caller
as
$$
begin
  -- dq is two dollar signs: the spec goes inside them, like a normal create agent.
  let dq varchar := '$' || '$';
  let ddl varchar := 'create or replace agent ' || agent_name || ' from specification '
                     || dq || replace(spec, '{WAREHOUSE}', current_warehouse()) || dq;
  execute immediate :ddl;
  return 'created ' || agent_name || ', tools run on ' || current_warehouse();
end;
$$;

-- ask(): data_agent_run returns the agent's whole reply as JSON. ask() keeps the
-- answer text, any result tables (as "col | col" lines), the tools used and any warnings.
-- data_agent_run only takes a constant request, so ask() writes the call as text
-- and runs it with execute immediate.
create or replace procedure ask(agent varchar, question varchar)
returns table (answer varchar, tools_used varchar, warnings variant)
language sql
execute as caller
as
$$
declare
  reply varchar;
begin
  let dq varchar := '$' || '$';
  let body varchar := to_json(object_construct('messages', array_construct(object_construct(
      'role', 'user',
      'content', array_construct(object_construct('type', 'text', 'text', question))))));
  let call_sql varchar := 'select snowflake.cortex.data_agent_run('''
      || current_database() || '.' || current_schema() || '.' || agent
      || ''', ' || dq || body || dq || ')';
  let rs resultset := (execute immediate :call_sql);
  let cur cursor for rs;
  open cur;
  fetch cur into reply;
  close cur;
  -- no content means an error: show its message instead.
  let res resultset := (
    select coalesce(nullif(listagg(
             case c.value:type::string
               when 'text' then c.value:text::string
               when 'table' then
                 array_to_string(transform(c.value:table:result_set:resultSetMetaData:rowType::array,
                                           col -> col:name::string), ' | ') || '\n' ||
                 array_to_string(transform(c.value:table:result_set:data::array,
                                           r -> array_to_string(r::array, ' | ')), '\n')
             end, '\n') within group (order by c.index), ''),
             any_value(try_parse_json(:reply):message::string)) as answer,
           array_to_string(array_distinct(array_agg(c.value:tool_use:name::string)), ', ') as tools_used,
           any_value(try_parse_json(:reply):warnings) as warnings
    from table(flatten(input => try_parse_json(:reply):content, outer => true)) c
  );
  return table(res);
end;
$$;

-- the store manager's agent. StoreData = Cortex Analyst on frostbites_sv (numbers).
-- Contracts = Cortex Search on contract_search (contract wording).
-- {WAREHOUSE} and {SCHEMA} are filled in by make_agent() and by you below.
call make_agent('store_manager_assistant', replace($$
models:
  orchestration: auto
instructions:
  response: "Answer in short, plain sentences. Show numbers in a small table when there are more than three."
  orchestration: "Use StoreData for sales, stock, suppliers and recommendations. Use Contracts for contract wording such as price per kg, weekly volume, delivery and who signed."
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "StoreData"
      description: "Frost Bites sales, stock left, supplier terms and shopper recommendations"
  - tool_spec:
      type: "cortex_search"
      name: "Contracts"
      description: "Full text of the four supplier contracts"
tool_resources:
  StoreData:
    semantic_view: "{SCHEMA}.frostbites_sv"
    execution_environment:
      type: "warehouse"
      warehouse: "{WAREHOUSE}"
  Contracts:
    search_service: "{SCHEMA}.contract_search"
    max_results: "3"
$$, '{SCHEMA}', $my_schema));

-- the manager's questions
call ask('store_manager_assistant', 'Which 5 fruits sold the most units, and at what hour of the day do sales peak?');
call ask('store_manager_assistant', 'Which 5 fruits have the least stock left?');
call ask('store_manager_assistant', 'Which suppliers offer a promotion or are certified organic?');
call ask('store_manager_assistant', 'What do we recommend to customer 1, and why?');
call ask('store_manager_assistant', 'Who supplies the durian, at what price per kg, and how much do they send each week?');
-- tools_used shows which tool answered. the last one needs Contracts:
-- price per kg and weekly volume are only in the contract text.


------------
-- 3.10 The shopper's assistant
------------
-- as a shopper you get your own role (storefront_xx) and see only these secure views.
-- a secure view runs as its owner (dba_xx), so storefront_xx needs no access to the
-- mirror or to vendor_terms. it also hides its definition from the shopper.
-- you are customer 1.
create or replace secure view my_picks as
select product_id, score, reason
from recommendations
where customer_id = 1;

create or replace secure view fruit_facts as
select p.product_id, p.name as fruit, p.category, p.flavor, p.texture, p.ways_to_eat, p.price,
       p.opening_stock - coalesce(s.sold, 0) > 0 as in_stock
from frostbites_mirror.store.products p
left join (select product_id, sum(qty) as sold
           from frostbites_mirror.store.sales
           where attendee <> 'store'
           group by product_id) s on s.product_id = p.product_id;

-- offers: organic and promo only. no supplier name, no wholesale price.
create or replace secure view offers as
select p.product_id, vt.is_organic, vt.promo_pct
from vendor_terms vt
join frostbites_mirror.store.products p on lower(p.name) = lower(vt.fruit);

-- my_purchases: only the sales you booked, as customer 1.
-- current_user() is whoever runs the query, so the view shows each person their own rows.
create or replace secure view my_purchases as
select line_id, order_id, ordered_at, product_id, fruit, qty, line_total
from frostbites_mirror.store.sales
where attendee = lower(current_user())
  and customer_id = 1;

-- the shopper's semantic view: built only on the secure views
create or replace semantic view shopper_sv
  tables (
    fruits as fruit_facts primary key (product_id)
      comment = 'Every fruit in the store: flavor, texture, ways to eat, price, in stock',
    picks as my_picks primary key (product_id)
      comment = 'Fruits recommended to me, with the reason',
    offers as offers primary key (product_id)
      comment = 'Fruits that are certified organic or on promotion',
    purchases as my_purchases primary key (line_id)
      comment = 'The fruits I bought before, one row per fruit per order'
  )
  relationships (
    picks (product_id) references fruits,
    offers (product_id) references fruits,
    purchases (product_id) references fruits
  )
  dimensions (
    fruits.fruit as fruits.fruit,
    fruits.category as fruits.category,
    fruits.flavor as fruits.flavor,
    fruits.texture as fruits.texture,
    fruits.ways_to_eat as fruits.ways_to_eat,
    fruits.price as fruits.price,
    fruits.in_stock as fruits.in_stock,
    picks.reason as picks.reason,
    picks.score as picks.score,
    offers.is_organic as offers.is_organic,
    offers.promo_pct as offers.promo_pct comment = 'Discount in percent, 0 if none',
    purchases.order_day as purchases.ordered_at::date
  )
  metrics (
    picks.pick_count as count(picks.product_id),
    purchases.order_count as count(distinct purchases.order_id),
    purchases.total_spent as sum(purchases.line_total),
    purchases.units_bought as sum(purchases.qty)
  )
  comment = 'One shopper: their picks, fruit facts, offers and purchases';

-- the shopper's agent: one tool, Analyst on shopper_sv. no contract search.
call make_agent('shopper_assistant', replace($$
models:
  orchestration: auto
instructions:
  response: "You help one Frost Bites shopper. Be friendly and brief. Say how to eat a fruit when you suggest it."
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "MyStore"
      description: "My recommended fruits, fruit facts, organic and promo offers, and my past purchases"
tool_resources:
  MyStore:
    semantic_view: "{SCHEMA}.shopper_sv"
    execution_environment:
      type: "warehouse"
      warehouse: "{WAREHOUSE}"
$$, '{SCHEMA}', $my_schema));

-- give storefront_xx exactly this, nothing more
grant select on view my_picks     to role identifier($sf_role);
grant select on view fruit_facts  to role identifier($sf_role);
grant select on view offers       to role identifier($sf_role);
grant select on view my_purchases to role identifier($sf_role);
grant select on semantic view shopper_sv to role identifier($sf_role);
grant usage on agent shopper_assistant to role identifier($sf_role);
grant usage on procedure ask(varchar, varchar) to role identifier($sf_role);


------------
-- 3.11 Prove the boundary
------------
-- switch to your shopper role. secondary roles none turns off every other role you
-- have (like dba_xx), so this session has only what storefront_xx was granted.
use role identifier($sf_role);
use secondary roles none;
use warehouse identifier($wh_name);
use schema identifier($my_schema);

-- your views work
select f.fruit, p.reason
from my_picks p
join fruit_facts f on f.product_id = p.product_id
order by p.score desc;

-- TRY: the tables behind them
select * from vendor_terms;
-- ERROR: does not exist or not authorized.
select count(*) from frostbites_mirror.store.sales;
-- ERROR: does not exist or not authorized.

-- ask your assistant
call ask('shopper_assistant', 'What fruit would I like that I have not bought yet, and how do I eat it?');
call ask('shopper_assistant', 'Are any of my suggestions on sale or certified organic?');
call ask('shopper_assistant', 'What have I bought before?');

-- now the manager's question
call ask('shopper_assistant', 'Who supplies the durian, and at what wholesale price?');
-- it can't say: no view your shopper role can read has supplier names or prices.

-- what if the shopper got the manager's assistant? give storefront_xx USAGE on it:
use role identifier($role_name);
use schema identifier($my_schema);
grant usage on agent store_manager_assistant to role identifier($sf_role);

use role identifier($sf_role);
use secondary roles none;
use schema identifier($my_schema);
call ask('store_manager_assistant', 'Who supplies the durian, and at what wholesale price?');
-- still no. the agent runs its tools as your shopper role, which can't read
-- frostbites_sv or contract_search. warnings shows TOOL_NOT_ACCESSIBLE for both.

-- take it back, and ask the same question as the manager
use role identifier($role_name);
use schema identifier($my_schema);
revoke usage on agent store_manager_assistant from role identifier($sf_role);
call ask('store_manager_assistant', 'Who supplies the durian, and at what wholesale price?');
-- same question, different role, different answer.

-- in production, a row access policy maps each signed-in shopper to their own
-- customer_id, so one set of views serves every shopper.

-- End of Lab #3B.
