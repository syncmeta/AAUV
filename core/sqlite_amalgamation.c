//go:build android || aauv_bundled_sqlite

// Android's NDK does not provide the platform SQLite library to apps.
// Scripts/prepare-android-sqlite.sh supplies the pinned amalgamation.
#include "sqlite3.c"
