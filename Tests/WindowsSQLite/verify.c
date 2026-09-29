#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "SQLite verification failed at line %d: %s\n", __LINE__, #condition); \
        return 1; \
    } \
} while (0)

static void execute(sqlite3 *database, const char *sql) {
    char *message = NULL;
    if (sqlite3_exec(database, sql, NULL, NULL, &message) != SQLITE_OK) {
        fprintf(stderr, "SQLite SQL verification failed: %s\n", message);
        sqlite3_free(message);
        exit(1);
    }
}

static int scalar(sqlite3 *database, const char *sql) {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) != SQLITE_OK ||
        sqlite3_step(statement) != SQLITE_ROW) {
        fprintf(stderr, "SQLite scalar verification failed: %s\n", sqlite3_errmsg(database));
        exit(1);
    }
    int result = sqlite3_column_int(statement, 0);
    if (sqlite3_finalize(statement) != SQLITE_OK) exit(1);
    return result;
}

int main(int argc, char **argv) {
    REQUIRE(argc == 3);
    REQUIRE(strcmp(sqlite3_libversion(), argv[2]) == 0);
    REQUIRE(sqlite3_threadsafe() == 1);
    REQUIRE(sqlite3_compileoption_used("ENABLE_FTS5"));
    REQUIRE(sqlite3_compileoption_used("ENABLE_SNAPSHOT"));
    REQUIRE(sqlite3_compileoption_used("ENABLE_COLUMN_METADATA"));

    sqlite3 *reader = NULL;
    sqlite3 *writer = NULL;
    REQUIRE(sqlite3_open(argv[1], &reader) == SQLITE_OK);
    execute(reader, "PRAGMA journal_mode=WAL; CREATE TABLE entries(id INTEGER PRIMARY KEY);"
                    "INSERT INTO entries VALUES (1);");
    REQUIRE(sqlite3_open(argv[1], &writer) == SQLITE_OK);

    execute(reader, "BEGIN;");
    REQUIRE(scalar(reader, "SELECT count(*) FROM entries;") == 1);
    sqlite3_snapshot *snapshot = NULL;
    REQUIRE(sqlite3_snapshot_get(reader, "main", &snapshot) == SQLITE_OK);
    execute(writer, "INSERT INTO entries VALUES (2);");
    execute(reader, "COMMIT; BEGIN;");
    REQUIRE(sqlite3_snapshot_open(reader, "main", snapshot) == SQLITE_OK);
    REQUIRE(scalar(reader, "SELECT count(*) FROM entries;") == 1);
    execute(reader, "COMMIT;");
    sqlite3_snapshot_free(snapshot);
    REQUIRE(scalar(reader, "SELECT count(*) FROM entries;") == 2);

    execute(writer, "BEGIN; INSERT INTO entries VALUES (3); ROLLBACK;");
    REQUIRE(scalar(reader, "SELECT count(*) FROM entries;") == 2);
    execute(writer, "CREATE VIRTUAL TABLE search USING fts5(body);"
                    "INSERT INTO search VALUES ('owned runtime');");
    REQUIRE(scalar(reader, "SELECT count(*) FROM search WHERE search MATCH 'runtime';") == 1);

    const char *type = NULL;
    REQUIRE(sqlite3_table_column_metadata(reader, "main", "entries", "id", &type,
                                          NULL, NULL, NULL, NULL) == SQLITE_OK);
    REQUIRE(type != NULL && strcmp(type, "INTEGER") == 0);
    REQUIRE(sqlite3_close(writer) == SQLITE_OK);
    REQUIRE(sqlite3_close(reader) == SQLITE_OK);
    REQUIRE(sqlite3_shutdown() == SQLITE_OK);
    printf("{\"version\":\"%s\",\"serialized\":true,\"walSnapshot\":true,"
           "\"rollback\":true,\"fts5\":true,\"columnMetadata\":true}\n", sqlite3_libversion());
    return 0;
}
