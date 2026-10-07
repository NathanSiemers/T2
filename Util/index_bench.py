#!/usr/bin/env python3
"""Which indexes of a T2 database matter, and for what.

Runs the queries the applications really issue — the t2api service (one probe at a time,
by key), gitr() behind the Shiny apps (the tcgas/tcgacats views, a few probes at a time),
and larger requests we do not normally see (20, 30, 50, 100 probes in one statement) —
against a database file, cold (the file evicted from the page cache first) and warm, prints
each query's plan (EXPLAIN QUERY PLAN) and timing, and can drop an index from a BENCH COPY
to show what that index was buying.

    # sizes of every index (reads each index once; minutes on a 40 GB file)
    python3 Util/index_bench.py tcga.bench.db --sizes

    # the suite, cold and warm, with plans
    python3 Util/index_bench.py tcga.bench.db --run --out bench-full.json

    # drop an index (ONLY on a file whose name contains ".bench.") and run the suite again
    python3 Util/index_bench.py tcga.bench.db --drop typeidx --run --out bench-no-typeidx.json

    # compare two runs
    python3 Util/index_bench.py --compare bench-full.json bench-no-typeidx.json

Never point this at a served database with --drop: the safety check only lets a path with
".bench." in its name be modified, and everything else is opened read-only.

The probe sets are drawn with a fixed seed from the database itself (probe_types /
tcgacati), so two runs on the same data use the same probes; a cold run uses probes that
the warm-up has not touched. Timings are wall-clock seconds for fetching every row.
"""
import argparse, json, os, random, sqlite3, sys, time
from collections import OrderedDict

SEED = 20261007
# the kinds of statement, in the order they are run
TIERS = ["api", "gitr", "big", "typewide", "wholetype", "rna", "heavy"]


def connect(path, writable=False):
    if writable:
        if ".bench." not in os.path.basename(path):
            sys.exit(f"refusing to modify {path}: only a file named *.bench.* may be changed")
        return sqlite3.connect(path, timeout=60)
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)


def evict(path):
    """Drop the file's clean pages from the OS page cache (no root needed for our own file)."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)


def pick_probes(con, type_, n, rng, exclude=()):
    rows = con.execute("SELECT pr.probe, pr.key FROM probe_types pt JOIN probes pr ON pr.key = pt.probekey WHERE pt.type = ? ORDER BY pr.key", (type_,)).fetchall()
    rows = [r for r in rows if r[0] not in exclude]
    return rng.sample(rows, min(n, len(rows)))


def pick_cat_probes(con, type_, n, rng):
    rows = con.execute("SELECT DISTINCT pr.probe, pr.key FROM tcgacati d JOIN probes pr ON pr.key = d.probekey WHERE d.type = ? ORDER BY pr.key", (type_,)).fetchall()
    return rng.sample(rows, min(n, len(rows)))


def in_list(n):
    return ",".join("?" * n)


def build_suite(con):
    """The statements, with their parameters, grouped by tier. Each entry:
    (name, tier, sql, params, note)."""
    rng = random.Random(SEED)
    types = [t for (t,) in con.execute("SELECT DISTINCT type FROM probe_types ORDER BY type")]
    cat_types = [t for (t,) in con.execute("SELECT DISTINCT type FROM tcgacati ORDER BY type")]
    has = lambda t: t in types
    suite = []
    used = set()

    def take(type_, n):
        ps = pick_probes(con, type_, n, rng, exclude=used)
        used.update(p for p, _ in ps)
        return ps

    # ---- api: what t2api does for one probe (by key), per data type ---------------------
    for t in [t for t in ["rna", "cnv", "cnc", "mut", "sig", "urna", "rppa", "estimate"] if has(t)]:
        (probe, key), = take(t, 1)
        suite.append((f"api probe key lookup ({probe})", "api", "SELECT key FROM probes WHERE probe = ?", (probe,), "probes autoindex / probesidx"))
        suite.append((f"api probe type ({probe})", "api", "SELECT type FROM probe_types WHERE probekey = ? ORDER BY rowid LIMIT 1", (key,), "probe_types_pk"))
        suite.append((f"api values {t} ({probe})", "api", "SELECT samplekey, value FROM tcgai WHERE probekey = ? AND type = ?", (key, t), "tcgaiidx_pts covering"))
    for t in cat_types[:3]:
        (probe, key), = pick_cat_probes(con, t, 1, rng)
        suite.append((f"api categorical values {t} ({probe})", "api", "SELECT samplekey, value, type FROM tcgacati WHERE probekey = ?", (key,), "tcgacatiidx_pts"))
    suite.append(("api startup clinpheno", "api", "SELECT * FROM clinpheno", (), "table scan, once per start"))
    suite.append(("api startup tested", "api", "SELECT t.type, t.sample FROM tested t JOIN samples sa ON sa.sample = t.sample", (), "samples autoindex / samplesidx"))
    suite.append(("api startup allprobes", "api", "SELECT probe FROM allprobes", (), "table scan, once per start"))

    # ---- gitr: the Shiny apps' statements through the views ----------------------------
    for n in (1, 2, 5):
        ps = take("rna", n) if has("rna") else []
        if ps:
            suite.append((f"gitr tcgas {n} rna probe(s)", "gitr", f"SELECT sample, probe, value FROM tcgas WHERE probe IN ({in_list(n)})", tuple(p for p, _ in ps), "probes -> probe_types_pk -> tested_type -> tcgaiidx_pts"))
    if has("rna") and has("mut"):
        ps = take("rna", 1) + take("mut", 1) + (take("cnv", 1) if has("cnv") else [])
        suite.append(("gitr tcgas mixed types (rna+mut+cnv)", "gitr", f"SELECT sample, probe, value FROM tcgas WHERE probe IN ({in_list(len(ps))})", tuple(p for p, _ in ps), "one probe per type"))
    if cat_types:
        ps = pick_cat_probes(con, cat_types[0], 3, rng)
        suite.append((f"gitr tcgacats 3 {cat_types[0]} probes", "gitr", f"SELECT sample, probe, value FROM tcgacats WHERE probe IN ({in_list(len(ps))})", tuple(p for p, _ in ps), "tcgacatiidx_pts"))
    ps = take("rna", 3) if has("rna") else []
    if ps:
        suite.append(("gitr probe types of 3 probes", "gitr", f"SELECT pr.probe, pt.type FROM probes pr JOIN probe_types pt ON pt.probekey = pr.key WHERE pr.probe IN ({in_list(3)})", tuple(p for p, _ in ps), "probes autoindex + probe_types_pk"))
        suite.append(("gitr tcga view + tumtype filter (1 probe, STAD)", "gitr", "SELECT sample, probe, value FROM tcga WHERE probe = ? AND tumtype = 'STAD'", (ps[0][0],), "clinpheno_tumtype_sample?"))
        suite.append(("gitr tcga view with clinpheno (1 probe)", "gitr", "SELECT * FROM tcga WHERE probe = ?", (ps[1][0],), "clinphenoidx"))

    # ---- big: requests we do not see in routine use ------------------------------------
    for n in (20, 30, 50, 100):
        ps = take("rna", n) if has("rna") else []
        if len(ps) == n:
            suite.append((f"big tcgas {n} rna probes", "big", f"SELECT sample, probe, value FROM tcgas WHERE probe IN ({in_list(n)})", tuple(p for p, _ in ps), "view, IN list"))
    for n in (20, 50, 100):
        ps = take("rna", n) if has("rna") else []
        if len(ps) == n:
            suite.append((f"big tcgai {n} rna probes by key (api-style batch)", "big", f"SELECT probekey, samplekey, value FROM tcgai WHERE type = 'rna' AND probekey IN ({in_list(n)})", tuple(k for _, k in ps), "tcgaiidx_pts, IN list"))
    if has("cnv"):
        ps = take("cnv", 50)
        suite.append(("big tcgas 50 cnv probes", "big", f"SELECT sample, probe, value FROM tcgas WHERE probe IN ({in_list(len(ps))})", tuple(p for p, _ in ps), "dense type"))
    if has("mut"):
        ps = take("mut", 100)
        suite.append(("big tcgas 100 mut probes", "big", f"SELECT sample, probe, value FROM tcgas WHERE probe IN ({in_list(len(ps))})", tuple(p for p, _ in ps), "sparse type: view fills the zeros"))
    if cat_types:
        ps = pick_cat_probes(con, cat_types[0], 50, rng)
        suite.append((f"big tcgacats 50 {cat_types[0]} probes", "big", f"SELECT sample, probe, value FROM tcgacats WHERE probe IN ({in_list(len(ps))})", tuple(p for p, _ in ps), "tcgacatiidx_pts"))

    # ---- typewide: statements that look at a whole data type ---------------------------
    for t in [t for t in ["sig", "rppa", "estimate"] if has(t)]:
        suite.append((f"typewide count tcgai type {t}", "typewide", "SELECT count(*) FROM tcgai WHERE type = ?", (t,), "typeidx?"))
    if has("rppa"):
        suite.append(("typewide probes of type rppa with counts", "typewide", "SELECT probekey, count(*) FROM tcgai WHERE type = 'rppa' GROUP BY probekey", (), "typeidx vs probe_types_tp + tcgaiidx_pts"))
    suite.append(("typewide probe_types by type (mut)", "typewide", "SELECT probekey FROM probe_types WHERE type = 'mut'", (), "probe_types_tp"))
    if cat_types:
        suite.append((f"typewide tcgacats type {cat_types[-1]}", "typewide", "SELECT sample, probe, value FROM tcgacats WHERE type = ?", (cat_types[-1],), "tcgacatiidx_tsp"))
    suite.append(("typewide tested samples of one type", "typewide", "SELECT sample FROM tested WHERE type = 'rna'", (), "tested_type / tested_type_sample"))
    suite.append(("typewide allprobes LIKE search", "typewide", "SELECT probe FROM allprobes WHERE probe LIKE 'CD8%'", (), "no index use (LIKE)"))

    # ---- wholetype: "give me all the data of one type", three ways ----------------------
    # (a) the bare statement, which can use typeidx or must scan; (b) through probe_types
    # (type -> its probes) and the covering index, one contiguous range per probe; (c) the
    # probes of the type with their row counts, the same two ways. rna is a third of tcgai
    # and is the one that takes minutes whatever the route; opt in with --tiers wholetype,rna
    for t in [t for t in ["estimate", "sig", "rppa"] if has(t)]:
        suite.append((f"wholetype bare {t}", "wholetype", "SELECT probekey, samplekey, value FROM tcgai WHERE type = ?", (t,), "typeidx or full scan"))
        suite.append((f"wholetype via probe_types {t}", "wholetype",
                      "SELECT d.probekey, d.samplekey, d.value FROM probe_types pt JOIN tcgai d ON d.probekey = pt.probekey AND d.type = pt.type WHERE pt.type = ?", (t,),
                      "probe_types_tp + tcgaiidx_pts"))
        suite.append((f"wholetype probe counts via probe_types {t}", "wholetype",
                      "SELECT pt.probekey, count(*) FROM probe_types pt JOIN tcgai d ON d.probekey = pt.probekey AND d.type = pt.type WHERE pt.type = ? GROUP BY pt.probekey", (t,),
                      "probe_types_tp + tcgaiidx_pts"))
    if has("rna"):
        suite.append(("rna bare", "rna", "SELECT probekey, samplekey, value FROM tcgai WHERE type = 'rna'", (), "195 M rows: typeidx or full scan"))
        suite.append(("rna via probe_types", "rna",
                      "SELECT d.probekey, d.samplekey, d.value FROM probe_types pt JOIN tcgai d ON d.probekey = pt.probekey AND d.type = pt.type WHERE pt.type = 'rna'", (),
                      "195 M rows through the covering index"))

    # ---- heavy: things no index supports today (full scans), opt in ---------------------
    (sample_key,) = con.execute("SELECT key FROM samples ORDER BY key LIMIT 1 OFFSET min(100, (SELECT count(*) FROM samples) - 1)").fetchone()
    suite.append(("heavy one sample across tcgai", "heavy", "SELECT probekey, type, value FROM tcgai WHERE samplekey = ?", (sample_key,), "FULL SCAN of tcgai: no sample-leading index"))
    suite.append(("heavy count distinct probekey in tcgai (rna)", "heavy", "SELECT count(DISTINCT probekey) FROM tcgai WHERE type = 'rna'", (), "index-only on tcgaiidx_pts or typeidx"))
    return suite


def plan(con, sql, params):
    return [r[3] for r in con.execute("EXPLAIN QUERY PLAN " + sql, params)]


def run_one(con, sql, params):
    t0 = time.perf_counter()
    n = 0
    for _ in con.execute(sql, params):
        n += 1
    return time.perf_counter() - t0, n


def run_suite(path, tiers, do_cold, out):
    con = connect(path)
    con.execute("PRAGMA cache_size = -65536")  # 64 MB page cache: the apps' order of magnitude
    suite = [s for s in build_suite(con) if s[1] in tiers]
    indexes = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")]
    results = []
    print(f"{path}: {len(suite)} statements, indexes: {', '.join(indexes)}\n")
    print(f"{'statement':62} {'cold s':>8} {'warm s':>8} {'rows':>9}  plan")
    for name, tier, sql, params, note in suite:
        p = plan(con, sql, params)
        cold = None
        if do_cold:
            con.close()
            evict(path)
            con = connect(path)
            con.execute("PRAGMA cache_size = -65536")
            cold, n = run_one(con, sql, params)
        warm, n = run_one(con, sql, params)
        results.append(OrderedDict(name=name, tier=tier, sql=sql, params=list(params), note=note, plan=p, cold_s=cold, warm_s=warm, rows=n))
        print(f"{name[:62]:62} {('%.3f' % cold) if cold is not None else '   -':>8} {warm:8.3f} {n:9d}  {' | '.join(p)[:110]}")
        sys.stdout.flush()
    con.close()
    report = OrderedDict(database=path, size_bytes=os.path.getsize(path), indexes=indexes, tiers=tiers, results=results)
    if out:
        with open(out, "w") as f:
            json.dump(report, f, indent=1)
        print(f"\nwritten: {out}")
    return report


def sizes(path):
    con = connect(path)
    rows = con.execute("SELECT name, tbl_name FROM sqlite_master WHERE type IN ('index','table') AND name NOT LIKE 'sqlite_%' OR type='index' ORDER BY tbl_name, type DESC, name").fetchall()
    print(f"{'object':32} {'table':14} {'pages':>12} {'MB':>10}")
    total = 0
    for name, tbl in rows:
        (pages, bytes_) = con.execute("SELECT count(*), coalesce(sum(pgsize),0) FROM dbstat WHERE name = ?", (name,)).fetchone()
        total += bytes_
        print(f"{name:32} {tbl:14} {pages:12d} {bytes_/1e6:10.1f}")
        sys.stdout.flush()
    print(f"{'total':32} {'':14} {'':>12} {total/1e6:10.1f}   (file {os.path.getsize(path)/1e6:.1f} MB)")
    con.close()


def drop_index(path, name):
    con = connect(path, writable=True)
    (sql,) = con.execute("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", (name,)).fetchone() or (None,)
    if sql is None:
        sys.exit(f"{name}: no such index (or an automatic one)")
    before = con.execute("PRAGMA freelist_count").fetchone()[0]
    t0 = time.perf_counter()
    con.execute(f"DROP INDEX {name}")
    con.commit()
    after = con.execute("PRAGMA freelist_count").fetchone()[0]
    page = con.execute("PRAGMA page_size").fetchone()[0]
    print(f"dropped {name} in {time.perf_counter()-t0:.1f} s; it held {(after-before)*page/1e9:.2f} GB ({after-before} pages). To recreate: {sql}")
    con.close()


def compare(a_path, b_path):
    a = json.load(open(a_path)); b = json.load(open(b_path))
    bi = {r["name"]: r for r in b["results"]}
    print(f"A = {a['database']} ({', '.join(sorted(set(a['indexes']) - set(b['indexes'])))} only in A)")
    print(f"B = {b['database']} ({', '.join(sorted(set(b['indexes']) - set(a['indexes'])))} only in B)\n")
    print(f"{'statement':62} {'A cold':>8} {'B cold':>8} {'A warm':>8} {'B warm':>8}  plan changed")
    for r in a["results"]:
        s = bi.get(r["name"])
        if not s:
            continue
        f = lambda v: ("%.3f" % v) if v is not None else "-"
        changed = "" if r["plan"] == s["plan"] else "YES: " + " | ".join(s["plan"])[:80]
        print(f"{r['name'][:62]:62} {f(r['cold_s']):>8} {f(s['cold_s']):>8} {f(r['warm_s']):>8} {f(s['warm_s']):>8}  {changed}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("database", nargs="?")
    ap.add_argument("--run", action="store_true", help="run the suite")
    ap.add_argument("--tiers", default="api,gitr,big,typewide", help=f"comma list of {','.join(TIERS)} (wholetype = all rows of a type; rna and heavy = minutes each)")
    ap.add_argument("--no-cold", action="store_true", help="skip the cold (page-cache-evicted) runs")
    ap.add_argument("--sizes", action="store_true", help="size of every table and index (dbstat; slow)")
    ap.add_argument("--drop", metavar="INDEX", help="drop this index first (bench copy only)")
    ap.add_argument("--out", help="write the run as JSON")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    a = ap.parse_args()
    if a.compare:
        return compare(*a.compare)
    if not a.database:
        ap.error("database path needed")
    if a.drop:
        drop_index(a.database, a.drop)
    if a.sizes:
        sizes(a.database)
    if a.run:
        tiers = [t for t in a.tiers.split(",") if t]
        bad = set(tiers) - set(TIERS)
        if bad:
            ap.error(f"unknown tiers {bad}")
        run_suite(a.database, tiers, not a.no_cold, a.out)


if __name__ == "__main__":
    main()
