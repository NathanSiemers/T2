module fiveprime.org/t2api

go 1.23

// v1.38.2: the last line that builds with Go 1.23 and no longer takes one process-wide lock
// for every SQLite mutex operation (v1.34.1 did: uncached lookups ran one at a time)
require modernc.org/sqlite v1.38.2
