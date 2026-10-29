#!/usr/bin/env python3
"""
metrics.py : HYSTERoC result analysis (spec 12). Python 3 standard library only.

Reads the logs written by tb/pm_log.vh for one run, with a common PREFIX:
    PREFIX_packets.csv   cycle,dst,src,pid,lat_total,lat_net,in_window
    PREFIX_switches.csv  cycle,new_mode,in_window
    PREFIX_blocks.csv    start,end,in_window_start       (end = -1: still blocked)
    PREFIX_summary.txt   key=value (counters of the performance_monitor)

Commands
  report  PREFIX [--tpp 50,100,200,400] [--no-check] [--warmup N --measure N]
      Print every metric of spec 12.2 / 12.3 recomputed from the logs, and (unless
      --no-check) compare each one with the counters of the RTL monitor. Exit
      code 1 if any value differs. The two are independent implementations.
  compare BASELINE CANDIDATE [--tpp 200]
      Evaluate the project acceptance targets of spec 12.5 for CANDIDATE against
      BASELINE (both are PREFIXes of runs on the SAME workload and seeds).
  csv PREFIX [PREFIX ...] --out FILE
      One row of metrics per run, for a spreadsheet.

Definitions (all stated again in DECISIONS.md)
  window            cycles warmup .. warmup+measure-1 (from the summary file or
                    --warmup/--measure); a packet is in the window if its tail
                    reached the sink (pulse) inside it.
  completed switch  the cycle in which the new mode is first visible.
  ping-pong event   a completed switch whose previous completed switch was at most
                    T_PP cycles earlier, both inside the window (each switch is
                    paired with the one immediately before it only).
  dwell             cycles between consecutive completed switches, both in window.
  blocked period    first .. last cycle of inject_block_req = 1; its length is the
                    drain duration (the cycle in which injection is released
                    is the last cycle of the period).
  blocked fraction  blocked cycles inside the window / measure (this is also the
                    "transition-related lost cycles" measure used for 12.5).
  latency           total = tail accepted at sink - packet created (primary);
                    network = tail accepted - header first offered (secondary).
                    mean, population standard deviation and p99 (nearest rank:
                    sorted ascending, element number ceil(0.99 n)).
  throughput        delivered packets / measure, and flits (4 per packet) / measure.
"""
import argparse, csv, math, os, sys

FLITS_PER_PACKET = 4


def read_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def read_summary(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path, errors="replace") as f:
        for line in f:
            line = line.replace("\x00", "").strip()
            if "=" in line:
                k, v = line.split("=", 1)
                d[k] = v.replace("\x00", "").strip()
    return d


def num(d, k, default=None):
    try:
        return int(d[k])
    except (KeyError, ValueError):
        return default


def percentile_nr(sorted_vals, p):
    """nearest rank percentile (p in 0..100)"""
    if not sorted_vals:
        return None
    k = max(1, math.ceil(p / 100.0 * len(sorted_vals)))
    return sorted_vals[k - 1]


def stats(vals):
    n = len(vals)
    if n == 0:
        return dict(n=0, mean=None, std=None, p99=None, max=None)
    s = sorted(vals)
    mean = sum(vals) / n
    var = sum((v - mean) ** 2 for v in vals) / n
    return dict(n=n, mean=mean, std=math.sqrt(var), p99=percentile_nr(s, 99), max=s[-1])


def analyse(prefix, tpps, warmup=None, measure=None):
    pk = read_csv(prefix + "_packets.csv")
    sw = read_csv(prefix + "_switches.csv")
    bl = read_csv(prefix + "_blocks.csv")
    sm = read_summary(prefix + "_summary.txt")
    W = warmup if warmup is not None else num(sm, "warmup")
    M = measure if measure is not None else num(sm, "measure")
    if W is None or M is None:
        sys.exit("window unknown: no summary file, give --warmup and --measure")
    r = dict(prefix=prefix, tag=sm.get("tag", os.path.basename(prefix)), warmup=W, measure=M)

    # ---- packets (in window) ----
    lt = [int(x["lat_total"]) for x in pk if x["in_window"] == "1"]
    ln = [int(x["lat_net"]) for x in pk if x["in_window"] == "1"]
    r["lat_total"] = stats(lt)
    r["lat_net"] = stats(ln)
    r["pkts"] = len(lt)
    r["tp_pkts_per_cycle"] = len(lt) / M if M else None
    r["tp_flits_per_cycle"] = len(lt) * FLITS_PER_PACKET / M if M else None
    r["pkts_total_all"] = len(pk)
    r["lat_total_sum"] = sum(lt)
    r["lat_net_sum"] = sum(ln)
    r["lat_total_sq"] = sum(v * v for v in lt)
    r["lat_net_sq"] = sum(v * v for v in ln)

    # ---- switching ----
    swc = [(int(x["cycle"]), int(x["new_mode"]), x["in_window"] == "1") for x in sw]
    r["sw_total"] = len(swc)
    inwin = [s for s in swc if s[2]]
    r["switches"] = len(inwin)
    r["to_adapt"] = sum(1 for s in inwin if s[1] == 1)
    r["to_xy"] = sum(1 for s in inwin if s[1] == 0)
    r["switch_rate_per_1000"] = len(inwin) * 1000.0 / M if M else None
    pp = {t: 0 for t in tpps}
    gaps = []
    for i in range(1, len(swc)):
        a, b = swc[i - 1], swc[i]
        if a[2] and b[2]:
            g = b[0] - a[0]
            gaps.append(g)
            for t in tpps:
                if g <= t:
                    pp[t] += 1
    r["pingpong"] = pp
    r["dwell_n"] = len(gaps)
    r["dwell_sum"] = sum(gaps)
    r["dwell_mean"] = (sum(gaps) / len(gaps)) if gaps else None
    r["dwell_min"] = min(gaps) if gaps else None
    r["dwell_max"] = max(gaps) if gaps else None

    # ---- blocked periods ----
    closed = [(int(x["start"]), int(x["end"]), x["in_window_start"] == "1") for x in bl if int(x["end"]) >= 0]
    opened = [(int(x["start"]), x["in_window_start"] == "1") for x in bl if int(x["end"]) < 0]
    lens = [e - s + 1 for (s, e, w) in closed if w]
    r["drain_n"] = len(lens)
    r["drain_sum"] = sum(lens)
    r["drain_mean"] = (sum(lens) / len(lens)) if lens else None
    r["drain_min"] = min(lens) if lens else None
    r["drain_max"] = max(lens) if lens else None
    r["open_block"] = len(opened) > 0
    blocked = 0
    lo, hi = W, W + M - 1
    for (s, e, w) in closed:
        a, b = max(s, lo), min(e, hi)
        if b >= a:
            blocked += b - a + 1
    end_of_log = num(sm, "now")        # an open period lasts until the last simulated cycle
    if end_of_log is not None:
        for (s, w) in opened:
            a, b = max(s, lo), min(end_of_log - 1, hi)
            if b >= a:
                blocked += b - a + 1
    r["blocked_cycles"] = blocked
    r["blocked_fraction"] = blocked / M if M else None
    r["blk_starts"] = sum(1 for (s, e, w) in closed if lo <= s <= hi) + sum(1 for (s, w) in opened if lo <= s <= hi)

    r["summary"] = sm
    return r


def check_against_rtl(r, tpps):
    """compare the recomputed values with the performance_monitor counters"""
    sm = r["summary"]
    if not sm:
        return ["no summary file: nothing to compare"], 0
    bad, n = [], 0

    def eq(name, mine, key):
        nonlocal n
        theirs = num(sm, key)
        n += 1
        if theirs is None:
            bad.append(f"{name}: key {key} missing in summary")
        elif mine != theirs:
            bad.append(f"{name}: scripts={mine} RTL monitor={theirs}")

    eq("completed switches", r["switches"], "w_switches")
    eq("switches to adaptive", r["to_adapt"], "w_to_adapt")
    eq("switches to XY", r["to_xy"], "w_to_xy")
    eq("total switches (whole run)", r["sw_total"], "sw_total")
    for i, key in enumerate(["w_pp0", "w_pp1", "w_pp2", "w_pp3"]):
        t = num(sm, f"pp_t{i}")
        if t in r["pingpong"]:
            eq(f"ping-pong T_PP={t}", r["pingpong"][t], key)
    eq("dwell count", r["dwell_n"], "w_dwell_cnt")
    eq("dwell sum", r["dwell_sum"], "w_dwell_sum")
    if r["dwell_n"]:
        eq("dwell min", r["dwell_min"], "w_dwell_min")
        eq("dwell max", r["dwell_max"], "w_dwell_max")
    eq("packets in window", r["pkts"], "w_pkts")
    eq("total latency sum", r["lat_total_sum"], "w_lat_total_sum")
    eq("network latency sum", r["lat_net_sum"], "w_lat_net_sum")
    eq("total latency sum of squares", r["lat_total_sq"], "w_lat_total_sq")
    eq("network latency sum of squares", r["lat_net_sq"], "w_lat_net_sq")
    eq("total latency max", r["lat_total"]["max"] or 0, "w_lat_total_max")
    eq("network latency max", r["lat_net"]["max"] or 0, "w_lat_net_max")
    eq("blocked cycles", r["blocked_cycles"], "w_blocked")
    eq("blocked periods (drain count)", r["drain_n"], "drain_cnt")
    eq("drain duration sum", r["drain_sum"], "drain_sum")
    if r["drain_n"]:
        eq("drain duration min", r["drain_min"], "drain_min")
        eq("drain duration max", r["drain_max"], "drain_max")
    eq("block requests started", r["blk_starts"], "w_blk_starts")
    eq("packets (whole run)", r["pkts_total_all"], "pkts_total")
    return bad, n


def fmt(v, nd=2):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def print_report(r, tpps):
    L = r["lat_total"]
    N = r["lat_net"]
    print(f"== {r['tag']}  ({r['prefix']})  window {r['warmup']}..{r['warmup'] + r['measure'] - 1}  ({r['measure']} cycles)")
    print(f"  completed switches      : {r['switches']}  (to adaptive {r['to_adapt']}, to XY {r['to_xy']})   whole run {r['sw_total']}")
    print(f"  switch rate             : {fmt(r['switch_rate_per_1000'])} per 1000 cycles")
    print("  ping-pong events        : " + ", ".join(f"T_PP={t}: {r['pingpong'][t]}" for t in tpps))
    print(f"  dwell time              : mean {fmt(r['dwell_mean'])}, min {fmt(r['dwell_min'])}, max {fmt(r['dwell_max'])}  ({r['dwell_n']} intervals)")
    print(f"  block requests started  : {r['blk_starts']}   completed blocked periods in window: {r['drain_n']}" + ("   [a blocked period is still open]" if r['open_block'] else ""))
    print(f"  drain duration (cycles) : mean {fmt(r['drain_mean'])}, min {fmt(r['drain_min'])}, max {fmt(r['drain_max'])}")
    print(f"  injection-blocked frac. : {fmt(r['blocked_fraction'], 4)}  ({r['blocked_cycles']} cycles)")
    print(f"  total latency  (primary): mean {fmt(L['mean'])}, std {fmt(L['std'])}, p99 {fmt(L['p99'])}, max {fmt(L['max'])}")
    print(f"  network latency         : mean {fmt(N['mean'])}, std {fmt(N['std'])}, p99 {fmt(N['p99'])}, max {fmt(N['max'])}")
    print(f"  throughput              : {fmt(r['tp_pkts_per_cycle'], 4)} packets/cycle, {fmt(r['tp_flits_per_cycle'], 4)} flits/cycle  ({r['pkts']} packets)")


def reduction(base, cand):
    if base is None or cand is None:
        return None
    if base == 0:
        return None
    return (base - cand) / base * 100.0


def cmd_report(a):
    tpps = [int(x) for x in a.tpp.split(",")]
    r = analyse(a.prefix, tpps, a.warmup, a.measure)
    # the monitor's four T_PP values may differ from --tpp: add them so they can be checked
    sm = r["summary"]
    extra = [num(sm, f"pp_t{i}") for i in range(4) if num(sm, f"pp_t{i}") is not None]
    all_t = sorted(set(tpps) | set(extra))
    if all_t != tpps:
        r = analyse(a.prefix, all_t, a.warmup, a.measure)
    print_report(r, tpps)
    if a.no_check:
        return 0
    bad, n = check_against_rtl(r, all_t)
    if bad and bad[0].startswith("no summary"):
        print("  check: " + bad[0])
        return 0
    if bad:
        print(f"  CHECK FAILED ({len(bad)} of {n} values differ from the RTL monitor):")
        for b in bad:
            print("    " + b)
        return 1
    print(f"  check: all {n} values equal the RTL monitor counters")
    return 0


def level(frac):
    if frac is None:
        return "n/a"
    if frac < 0.05:
        return "OK (< 5 %)"
    if frac <= 0.10:
        return "INVESTIGATE (5-10 %)"
    return "UNSUITABLE (> 10 %)"


def cmd_compare(a):
    t = a.tpp
    b = analyse(a.baseline, [50, 100, 200, 400])
    c = analyse(a.candidate, [50, 100, 200, 400])
    print(f"baseline : {b['tag']}   candidate : {c['tag']}   (T_PP for the criterion = {t})")
    fails = 0

    def row(name, ok, text):
        nonlocal fails
        mark = "PASS" if ok is True else ("FAIL" if ok is False else "n/a ")
        if ok is False:
            fails += 1
        print(f"  [{mark}] {name}: {text}")

    red = reduction(b["switch_rate_per_1000"], c["switch_rate_per_1000"])
    row("switch rate reduced by >= 50 %", None if red is None else red >= 50.0,
        f"{fmt(b['switch_rate_per_1000'])} -> {fmt(c['switch_rate_per_1000'])} per 1000 cycles ({'n/a, baseline has no switches' if red is None else fmt(red, 1) + ' % reduction'})")
    redp = reduction(b["pingpong"][t], c["pingpong"][t])
    row("ping-pong events reduced by >= 50 %", None if redp is None else redp >= 50.0,
        f"{b['pingpong'][t]} -> {c['pingpong'][t]} ({'n/a, baseline has none' if redp is None else fmt(redp, 1) + ' % reduction'})")
    for tt in (50, 100, 200, 400):
        print(f"        (sensitivity T_PP={tt}: baseline {b['pingpong'][tt]}, candidate {c['pingpong'][tt]})")
    bm, cm = b["lat_total"]["mean"], c["lat_total"]["mean"]
    if bm is not None and cm is not None and bm > 0:
        worse = (cm - bm) / bm * 100.0
        row("mean total latency no more than 5 % worse", worse <= 5.0, f"{fmt(bm)} -> {fmt(cm)} ({fmt(worse, 1)} % {'worse' if worse > 0 else 'better'})")
    bp, cp = b["lat_total"]["p99"], c["lat_total"]["p99"]
    if bp is not None and cp is not None:
        row("p99 total latency no worse", cp <= bp, f"{bp} -> {cp}")
    bt, ct = b["tp_flits_per_cycle"], c["tp_flits_per_cycle"]
    print(f"  [info] throughput flits/cycle: {fmt(bt, 4)} -> {fmt(ct, 4)}")
    print(f"  [info] blocked fraction: baseline {fmt(b['blocked_fraction'], 4)} {level(b['blocked_fraction'])}; candidate {fmt(c['blocked_fraction'], 4)} {level(c['blocked_fraction'])}")
    print(f"  [info] drain duration mean: baseline {fmt(b['drain_mean'])}, candidate {fmt(c['drain_mean'])}")
    print("  zero lost/duplicated/corrupted/reordered packets and zero stall-watchdog events are checked by the")
    print("  system testbench (sink error counters, scoreboard, stall flag), not by this script.")
    return 1 if fails else 0


def cmd_csv(a):
    rows = []
    for p in a.prefixes:
        r = analyse(p, [50, 100, 200, 400])
        rows.append({
            "tag": r["tag"], "prefix": p, "measure": r["measure"], "switches": r["switches"],
            "switch_rate_per_1000": r["switch_rate_per_1000"],
            "pp_50": r["pingpong"][50], "pp_100": r["pingpong"][100], "pp_200": r["pingpong"][200], "pp_400": r["pingpong"][400],
            "dwell_mean": r["dwell_mean"], "dwell_min": r["dwell_min"],
            "drain_mean": r["drain_mean"], "drain_max": r["drain_max"], "blocked_fraction": r["blocked_fraction"],
            "lat_total_mean": r["lat_total"]["mean"], "lat_total_std": r["lat_total"]["std"], "lat_total_p99": r["lat_total"]["p99"],
            "lat_net_mean": r["lat_net"]["mean"], "lat_net_p99": r["lat_net"]["p99"],
            "pkts": r["pkts"], "pkts_per_cycle": r["tp_pkts_per_cycle"], "flits_per_cycle": r["tp_flits_per_cycle"],
        })
    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {a.out} ({len(rows)} rows)")
    return 0


def main():
    ap = argparse.ArgumentParser(description="HYSTERoC metrics (spec 12)")
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("report")
    p.add_argument("prefix")
    p.add_argument("--tpp", default="50,100,200,400")
    p.add_argument("--no-check", action="store_true")
    p.add_argument("--warmup", type=int)
    p.add_argument("--measure", type=int)
    p.set_defaults(fn=cmd_report)
    p = sp.add_parser("compare")
    p.add_argument("baseline")
    p.add_argument("candidate")
    p.add_argument("--tpp", type=int, default=200, choices=[50, 100, 200, 400])
    p.set_defaults(fn=cmd_compare)
    p = sp.add_parser("csv")
    p.add_argument("prefixes", nargs="+")
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_csv)
    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
