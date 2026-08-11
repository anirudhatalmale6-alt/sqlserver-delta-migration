================================================================================
CATCHING UP THE NEW SQL SERVER
Moving everything written since 30 July 2026 from VM0810 to VM1535
================================================================================

WHAT THIS IS

The data was copied to the new server around 30 July. Since then the old
server has carried on taking real customer payments, so there is roughly two
weeks of data sitting on VM0810 that VM1535 has never seen.

These scripts move that gap across, table by table, without disturbing what
is already on the new server.

They are built so you can adjust them yourself. Everything is driven by one
small text file, tables.csv, with one line per table. Nothing is hard-coded
to any particular table name.

Nothing writes to the old server at any point. It is only ever read.


--------------------------------------------------------------------------------
READ THIS FIRST - WHICH FILE OPENS IN WHAT
--------------------------------------------------------------------------------

There are three kinds of file in this folder and they are NOT interchangeable.

  .sql   Open in SQL Server Management Studio. Press F5.

  .bat   DOUBLE-CLICK in Windows Explorer. It asks you a few questions and
         runs the matching .ps1 for you.

  .ps1   PowerShell. Do not open these yourself and do NOT paste them into
         SQL Server Management Studio - SSMS will try to read PowerShell as
         SQL and give you a screen full of "Incorrect syntax near" errors.
         Use the .bat files instead; that is what they are for.


--------------------------------------------------------------------------------
TWO ROUTES - PICK ONE
--------------------------------------------------------------------------------

ROUTE A - EVERYTHING INSIDE SSMS, NOTHING TO INSTALL      07_ssms_only_...sql

  Start here if you would rather not deal with PowerShell at all.

  You open one .sql file on the OLD server, change four lines at the top,
  press F5, and it writes a complete ready-to-run INSERT script for you in
  the Messages tab. Copy that, paste it into a query window on the NEW
  server, and run it.

  It handles apostrophes, NULLs, dates, GUIDs and Danish characters, wraps
  IDENTITY_INSERT around the insert where needed, and guards every row so
  running it twice cannot create duplicates.

  One table at a time, parents before children. Comfortable up to a few
  thousand rows per table.

  This is the simplest route and for a two-week gap it is very probably all
  you need.

ROUTE B - THE BCP ROUTE                        RUN_EXPORT.bat / RUN_IMPORT.bat

  Better for large tables, and it moves every table in one go rather than
  one at a time. Double-click RUN_EXPORT.bat on the old server, copy the
  output folder across, double-click RUN_IMPORT.bat on the new server, then
  finish in SSMS with 05 and 06.

Both routes end up in the same place. Route A involves more copying and
pasting; route B involves more setting up. Neither is more or less safe.


--------------------------------------------------------------------------------
THE ONE THING TO UNDERSTAND BEFORE YOU START
--------------------------------------------------------------------------------

This is the part that decides whether the job goes well or badly, so it is
worth two minutes.

Most of your tables give each new row an automatic ID number: 1, 2, 3 and so
on. Both servers have been doing that independently since 30 July, and both
of them carried on counting from the same place.

So the old server may have created Member number 11 - a real customer - and
the new server may have created a completely different Member number 11 for
one of your test payments. Same number, two different people.

If we simply copy the old rows across and insist on keeping their original
numbers, one of two things happens:

  * the insert is rejected with a duplicate key error. Annoying, but safe.

  * or the row is quietly skipped as "already there", and a real customer
    silently disappears. This is the dangerous one, because nothing tells
    you it happened.

Script 02 finds every table where this is a risk, and script 05 refuses to
stay quiet about it - it counts the rows it is about to skip and shouts if
they look suspicious. For the few tables that are genuinely affected, script
06 imports them with fresh ID numbers and automatically repairs every table
that pointed at the old numbers.

For most tables none of this applies and the plain copy is correct.


--------------------------------------------------------------------------------
WHAT YOU NEED
--------------------------------------------------------------------------------

  * SQL Server Management Studio, for the .sql files.
  * bcp.exe, for the two .ps1 files. It ships with SQL Server client tools
    and is almost certainly already on the servers. Check by opening a
    command prompt and typing:   bcp -v
  * PowerShell (the one built into Windows is fine).

The data files are written in SQL Server's own "native" format rather than
CSV. That is deliberate: Danish letters and decimal amounts come through
byte for byte, with no risk of ae/oe/aa turning into rubbish and no risk of a
comma inside a text field splitting a column in two.


--------------------------------------------------------------------------------
THE STEPS
--------------------------------------------------------------------------------

Do one database at a time. Start with the least important one to get a feel
for it - do not make DatingTid or GlobalMailServer your first attempt.


STEP 1 - see what you have got            01_discover_and_config.sql
--------------------------------------------------------------------------------
Run on the OLD server, with the database selected in the dropdown.

Reads only system tables, changes nothing.

It lists every table with its row count, its primary key, its automatic ID
column, and the date column that best identifies when a row was created. It
also works out the order the tables have to be handled in so that parents go
in before their children.

The second grid it produces is a ready-made config block. Copy those lines
into tables.csv (there is an example in this folder).


STEP 2 - find the risky tables            02_check_gap_and_collisions.sql
--------------------------------------------------------------------------------
Run on the OLD server, then again on the NEW server, same database.

Reads only, changes nothing.

On the OLD server, "RowsAfterCutoff" is how many rows we need to move.

On the NEW server, "RowsAfterCutoff" should normally be 0. Any table showing
more than 0 is a table where BOTH servers have been writing, which is exactly
the situation described above. Write those table names down - they are the
ones that need the special treatment in step 6.


STEP 3 - fill in tables.csv
--------------------------------------------------------------------------------
One line per table, columns separated by semicolons:

  Schema ; Table ; WhereClause ; KeyColumns ; KeepIdentity

  WhereClause   which rows to take from the old server.
                Normally  [Created] >= '2026-07-30'
                Leave it empty to take the whole table (fine for small
                lookup tables like a list of countries).

  KeyColumns    how to tell whether we already have a row, so nothing is
                imported twice. Where you have one, prefer a real business
                value - an order number, a QuickPay subscription id, an
                e-mail address - over the automatic ID.

  KeepIdentity  1 = keep the original ID numbers. This is the normal case.
                0 = let the new server allocate fresh ID numbers. Use this
                    for the tables step 2 flagged.

Lines starting with # are ignored, so you can work through a big database in
batches by commenting tables out.

A table with no date column at all is listed with an empty WhereClause. For
small lookup tables just take everything - the import skips what it already
has. For a large one, put in your own condition, for example
[ID] > 123456 using the highest ID that came over in the July backup.


STEP 4 - export from the old server       03_export_delta.ps1
--------------------------------------------------------------------------------
Run on the OLD server, or anywhere that can reach it. Read only.

  .\03_export_delta.ps1 -Server "VM0810" -Database "DatingTid" `
                        -User "your_sql_login" -Password "..." `
                        -ConfigFile ".\tables.csv" -OutDir "D:\delta\DatingTid"

You get one .dat file per table, plus manifest.csv and a full log.

Computed columns and rowversion columns are left out automatically - SQL
Server insists on filling those in itself.

Then copy the whole output folder over to the new server.


STEP 5 - load into staging                04_import_to_staging.ps1
--------------------------------------------------------------------------------
Run against the NEW server.

  .\04_import_to_staging.ps1 -Server "VM1535" -Database "DatingTid" `
                             -User "your_sql_login" -Password "..." `
                             -InDir "D:\delta\DatingTid"

This does NOT touch your real tables. Everything lands in a separate schema
called stg - stg.dbo_Members is a scratch copy of dbo.Members. If anything
looks wrong, drop the stg schema and start over. Your live data is not
involved in this step at all.


STEP 6 - look before you leap             05_generate_merge_sql.sql
--------------------------------------------------------------------------------
Run on the NEW server.

It installs a helper and then prints - without running any of it - the exact
INSERT statement it intends to use for every table, how many rows it will
skip, and a loud warning on any table where skipping might mean losing data.

Read that output. Then do one table for real:

  EXEC stg.usp_MergeDelta @Schema='dbo', @Table='Members', @Execute=1;

Check it. Then the rest, in the correct parent-before-child order:

  EXEC stg.usp_MergeDelta_All @Execute=1;

Every table runs inside its own transaction. If one fails it rolls back
completely - you never get half a table. Running it twice is harmless: the
second run inserts nothing.


STEP 7 - the awkward tables               06_merge_templates.sql
--------------------------------------------------------------------------------
Only for the tables step 2 flagged and step 6 shouted about.

First, look at the actual clash with your own eyes:

  EXEC stg.usp_ShowKeyClashes @Schema='dbo', @Table='Members';

This puts the old server's row directly above the row already sitting on the
new server with that same ID.

  * Same person, same dates? Then it was already migrated. Nothing to do.

  * Different people? Then import that table with fresh ID numbers:

      EXEC stg.usp_MergeDelta_Remap @Schema='dbo', @Table='Members',
                                    @BusinessKey='MemberGuid', @Execute=0;

    @Execute=0 shows you what it would do. When you are happy, run it again
    with @Execute=1.

    It inserts the rows with new IDs, records which old ID became which new
    ID in stg.__IdMap, and then automatically rewrites every staged table
    that pointed at the old number. Do the parent table first, then the
    children - the order is what makes the links come out right.

@BusinessKey must be something that means the same thing on both servers: a
member GUID, an e-mail address, a QuickPay subscription id, an order number.
Not the ID column - that is the value being replaced.


--------------------------------------------------------------------------------
SUGGESTED ORDER FOR YOUR DATABASES
--------------------------------------------------------------------------------

  1. A small, low-risk database first, to get comfortable.
  2. DatingTid
  3. DatingServicesCom
  4. GlobalMailServer  - last, and carefully. UserList and Domains are shared
     with MDaemon and hold all the live mailboxes, so treat that one as the
     most delicate of the set.

Take a backup of the new server's database before the first real run of each
one. It costs a few minutes and means any mistake is a restore rather than a
problem.


--------------------------------------------------------------------------------
IF SOMETHING GOES WRONG
--------------------------------------------------------------------------------

"Invalid object name stg.something"
    The import in step 5 did not run, or ran against a different database.

"Cannot insert explicit value for identity column"
    KeepIdentity is 1 but the table has no automatic ID, or vice versa.
    Check the setting for that line in tables.csv.

"Violation of PRIMARY KEY constraint"
    A genuine ID collision. That table needs step 7.

"String or binary data would be truncated"
    A column is narrower on the new server than on the old one. The two
    schemas have drifted apart - tell me which table and column and I will
    sort it out.

An SSL or certificate error from bcp
    Add  -TrustServerCert  to the PowerShell command.

Anything else - send me the log file from the output folder. Both scripts
write down everything they did.


--------------------------------------------------------------------------------
CLEANING UP
--------------------------------------------------------------------------------

Once a database is done and you have checked it, the staging data can go:

  DROP TABLE stg.__MergeConfig;
  DROP TABLE stg.__IdMap;          -- keep this one if you want the audit trail
  -- then drop the individual stg.* tables, or the whole schema

There is no hurry. Nothing reads from stg except these scripts.


--------------------------------------------------------------------------------
HOW THIS WAS TESTED
--------------------------------------------------------------------------------

I did not just write these and hope. I built two SQL Server instances here,
put the same data on both, and then deliberately recreated your exact
situation: the old one carried on adding real records while the new one
added its own, so that both ended up with different records sharing the same
ID numbers.

Then I ran the whole sequence and checked afterwards that

  * every migrated subscription still points at the right member,
  * every payment log still points at the right subscription,
  * the records created on the new server were left completely untouched,
  * no orphaned rows anywhere,
  * Danish characters survived exactly, and
  * running the entire thing a second time changes nothing at all.

The collision warning in step 6 exists because of that test. Without it, the
straightforward version of this job silently dropped three real customer
records and reported success.
================================================================================
