- FIX: queryconsoleview.lua: allow properly saving query as "filename"

- TODO: queryconsoleview.lua: add logic to keep track and handle more than one query console + results view at once
- TODO: tableview.lua: remove the gap between the rows' numbers column and the cells grid
- TODO: tableview.lua: make cells resizable (including width of field title cells)
- TODO: tableview.lua: add context menu with actions for editing cells/rows/columns

## Da riordinare

- TODO: modules: sqlite, postgres

- FUTURE_TODO: write a small C API to interact with the db (look at the official plugin template)

- TODO: debugger: make sure you can place a breakpoint on a line that returns a complex composite (assemebled with multipled 
        strings, ...) SQL query and ctrl+LMB click the query to be viewed separately

- TODO: use the formatter plugin to format a block of SQL code

- TODO: add table-specific query console (divide the tab view, bottom portion)
- TODO: bulk-edit of a table's rows
  (es. copy a vertical/horizontal selection of cells, then paste it into another table)

- TODO: column must be dinamically sized depending on width of either largest cell or column name
  (check that there is at least one connection active)

- TODO: store info about current connections in lua table in text file

- TODO: add command to refresh a db connection (with fuzzy suggest to list connections and commandview to choose one)

- TODO: add message (logs or right-side treeview ?) for when the current project db connection is not configured

- TODO: update messageview layout structure following Guldoman's Pockets PR

- TODO: add boolean variable (`is_prod = true/false`) to indicate if db treeview should be colored as RED
  (look how intellij does it)
  (instead of no custom color)
  (add custom colors ?)

- TODO: base DBView (for now create a new View on the right side)
  (todotreeview, outline, db will share right treeview)
  (build, debugger, db will share bottom drawer view)

- TODO: `db` and `lsp_sql` (with `sqls`) must share the DB connection details, maybe with `.lite_project.lua`

- TODO: le run delle query NON devono essere blocking (come faccio ?)

- TODO: add command to show all tables (like imports list of `lsp`) that refer to a selected (how ?) table field (through foreign key)
  (bind to F4, when pressing on a table field, either 
   - show all references[foreign keys] then go-to-table, focus field or 
   - go-to table, focus field
  )

- TODO: to navigate all tables: use a commandview!
  (use fuzzy search)

- TODO: `debugger` + `db` -> select  SQL query and evaluate it (use `debugger` to get parameter values and `db` to run it in the DB)
  (guarda come lo fa Intellij)

- TODO: (use .lite_module.lua to store db connection config)
- TODO: module system for connection types

- TODO: store query consoles and their query history
  (es. `lite-xl-db.lua`, like the workspaces plugin..., use same folder)

- TODO: add DDL read-only DocView for selected table
  (look how intellij does it; show the SQL code that creates the table, for read-only DocView look at how scm does it)

- TODO: Add db ER diagram view (?)
  (with go-to-table when clocking on an entity, requires db reader plugin)
  (study how the `equationgrapher` plugin works)
  (add loading icon while loading the ER diagram of the DB)

- TODO: add possibility of connecting to more than one db at the same time
  (and showing data from both at the same time, in separate views)


- FUTURE_TODO: controlla che ogni classe entita', che riconosce grazie ad una mappa, vedi sistema moduli, abbia una tabella
  corrispondente nel DB collegato al server LSP di `lsp_sql`
  (deps: `lsp_sql`, `lsp_*`)
