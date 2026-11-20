# Prerequisites: Frost Bites Supermarket Hands-on Lab

Two connections, two tools. Everything else is already set up for you.

---

## 1. Connect to Postgres (Lab 1)

Lab 1 runs in psql, a terminal-based Postgres client. Install it if you don't have it:

| OS | Command |
|---|---|
| Mac | `brew install libpq` (then follow the PATH note brew prints) |
| Windows | `winget install PostgreSQL.psql` |
| Linux | `apt install postgresql-client` or `yum install postgresql` |

Or use any Postgres GUI client: pgAdmin, DBeaver, or the VS Code PostgreSQL extension.

**Note:** Snowsight worksheets run SQL against Snowflake, not Postgres.
Lab 1 must run in psql or a Postgres client.

### Connect

Copy this command into your terminal. Replace `user_YOUR_HERO` with your
username from the attendee sheet (for example `user_batman`):

```
psql "host=qehalkbb4ramdo6eiqhski6ude.sfsenorthamerica-gshol.us-east-1.aws.postgres.snowflake.app port=5432 dbname=postgres user=user_YOUR_HERO sslmode=require"
```

Password: shared by the instructor in class.

You should see:
```
postgres=>
```

Type `\dt` to see your tables, then follow Lab 1.

---

## 2. Connect to Snowflake (Labs 2, 3, 4)

Labs 2, 3 and 4 run in Snowsight. No install needed, just a browser.

### Sign in

1. Open: https://app.snowflake.com/sfsenorthamerica/gshol/
2. Click the **Auth0** button (not the username/password fields)
3. Email: `YOUR_HERO@snowflake.com` (for example `batman@snowflake.com`)
4. Password: shared by the instructor in class

Your role and warehouse are already set. Open the lab files from
**Projects > Workspaces** or download them from
**Catalog > Databases > HOL > PUBLIC > Stages > LAB_FILES**.
