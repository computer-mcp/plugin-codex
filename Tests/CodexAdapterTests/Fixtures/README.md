# Database schema fixture

`codex-schema.json` is the complete ordered `sqlite_schema` projection
(`type`, `name`, `tbl_name` as `table`, `sql`) captured from a new database opened
by `CodexDatabase(path:)` at plugin commit
`b5dcc12ce58cb91342e1b844d8003675635ccb2d`. The capture applied all eight domain
migrations with the locked GRDB dependency, before the initial-schema squash.

`CodexDatabaseSchemaTests` compares the new database directly with this fixture,
including implicit indexes, primary/unique keys, nullability and SQL definitions.
The migration ledger's table definition is included; its row identifiers are
asserted separately. The fixture owns this regression baseline and must not be
regenerated from the implementation under test to make a mismatch pass.
