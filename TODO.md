- WIP: base TableView


- TODO: base DBView, requires Pockets system
  (todotreeview, outline, db will share right treeview)
  (build, debugger, db will share bottom drawer view)

- TODO: `db` and `lsp_sql` (with `sqls`) must share the DB connection details, maybe with `.lite_project.lua`

- TODO: add command to show all tables (like imports list of `lsp`) that refer to a selected (how ?) table field (through foreign key)

- TODO: `debugger` + `db` -> select  SQL query and evaluate it (use `debugger` to get parameter values and `db` to run it in the DB)
  (guarda come lo fa Intellij)

- TODO: (use .lite_module.lua to store db connection config)
- TODO: module system for connection types

- TODO: add DSL tab for selected table (look how intellij does it; show the SQL code that creates the table, read-only)

- TODO: Add db ER diagram view (?)
  (with go-to-table when clocking on an entity, requires db reader plugin)
  (study how the `equationgrapher` plugin works)
