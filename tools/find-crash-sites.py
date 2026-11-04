#!/usr/bin/env python3
"""Find big clear fields on the vanilla Muldraugh map for Aircraft Crash.

Writes shared/SEM/CrashSites.lua. Stdlib only. Reads the game folder as data.

Usage: python tools/find-crash-sites.py [--map "<Muldraugh, KY dir>"] [--out file.lua]

Method (see docs/bugs2/R17-crash-sites.md "Build"):
  S1  rasterise worldmap.xml / worldmap-forest.xml / objects.lua zones onto a
      4x4-tile grid (blocked = any blocker touches the cell).
  S2  add the lotpack: a 4x4 cell is free only if all 16 squares are bare
      natural ground (blends_natural_01 + grass overlays/groundcover/crops).
      Trees, bushes, fences, walls, floors, roofs, roads, water, void block.
  Distance transform (3-4 chamfer) -> clear radius per cell, then greedy
  non-maximum suppression, with extra sites reserved around each town.
"""
import argparse, array, glob, os, random, re, struct, sys, time, datetime
import xml.etree.ElementTree as ET
from multiprocessing import Pool

MAP = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY/"
CELL = 256            # lotpack cell, tiles
WCELL = 300           # worldmap.xml cell, units == tiles (verified against lotpack)
G = 4                 # grid cell, tiles
NX, NY = 78 * CELL // G, 63 * CELL // G
PLANE_R, HELI_R, CAP_R = 22, 14, 99
PLANE_SPACING, HELI_SPACING, MAX_SITES = 120, 80, 2500
BLOCK, TREE_MAX = 600, 0.15  # coverage: best site per 600x600 tile block, up to 15% tree squares
# objects.lua zone types that imply trees / buildings / water / roads
ZONE_BLOCK = {"Forest", "DeepForest", "Vegitation", "WaterZone", "WaterFlow", "TownZone",
              "Nav", "ParkingStall", "TrailerPark", "Basement", "ZoneStory", "LootZone"}
RELAX_SKIP = {"Forest", "DeepForest", "Vegitation"}  # tree-tolerant pass ignores these zones
TREE = ("vegetation_trees", "jumbo_tree", "vegetation_foliage", "f_bushes", "vegetation_ornamental")
OK_EXTRA = ("blends_grassoverlays", "blends_natural_01", "vegetation_groundcover", "vegetation_farm_01")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------- rasterising
def mark_rect(g, x0, y0, x1, y1):
    """Mark tile rect [x0,x1] x [y0,y1] inclusive."""
    for j in range(max(0, y0 // G), min(NY - 1, y1 // G) + 1):
        a = max(0, x0 // G); b = min(NX - 1, x1 // G)
        if b >= a:
            g[j * NX + a: j * NX + b + 1] = b"\x01" * (b - a + 1)


def mark_line(g, pts):
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(abs(x1 - x0), abs(y1 - y0)) // 2 + 1
        for k in range(n + 1):
            x = int(x0 + (x1 - x0) * k / n) // G; y = int(y0 + (y1 - y0) * k / n) // G
            if 0 <= x < NX and 0 <= y < NY:
                g[y * NX + x] = 1


def fill_poly(g, pts):
    ys = [p[1] for p in pts]
    for j in range(max(0, int(min(ys)) // G), min(NY - 1, int(max(ys)) // G) + 1):
        yc = j * G + G / 2
        xs = []
        for i in range(len(pts)):
            (x1, y1), (x2, y2) = pts[i], pts[i - 1]
            if (y1 > yc) != (y2 > yc):
                xs.append(x1 + (yc - y1) * (x2 - x1) / (y2 - y1))
        xs.sort()
        for a, b in zip(xs[0::2], xs[1::2]):
            i0 = max(0, int(a // G)); i1 = min(NX - 1, int(b // G))
            if i1 >= i0:
                g[j * NX + i0: j * NX + i1 + 1] = b"\x01" * (i1 - i0 + 1)
    mark_line(g, pts + pts[:1])


def raster_xml(g, path, towns=None):
    n = 0
    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag != "cell":
            continue
        ox, oy = int(el.get("x")) * WCELL, int(el.get("y")) * WCELL
        for f in el.findall("feature"):
            geo = f.find("geometry")
            pts = [(ox + int(p.get("x")), oy + int(p.get("y"))) for p in geo.find("coordinates")]
            t = geo.get("type")
            if t == "Point":
                pr = {p.get("name"): p.get("value") for p in f.find("properties")}
                if towns is not None and pr.get("place") == "town":
                    towns.append((pr.get("name_en", "?"), pts[0][0], pts[0][1]))
            elif t == "Polygon":
                fill_poly(g, pts); n += 1
            else:
                mark_line(g, pts); n += 1
        el.clear()
    return n


def raster_zones(g, path, block=ZONE_BLOCK):
    cnt = {}
    rx = re.compile(r'type = "(\w*)", x = (-?\d+), y = (-?\d+), z = (-?\d+), width = (\d+), height = (\d+)')
    for m in rx.finditer(open(path).read()):
        t, x, y, z, w, h = m.group(1), *map(int, m.groups()[1:])
        if t in block and z == 0:
            mark_rect(g, x, y, x + w - 1, y + h - 1); cnt[t] = cnt.get(t, 0) + 1
    return cnt


# ------------------------------------------------------------------- lotpack
def classify_names(names):
    """1 = allowed ground extra, 3 = tree/bush (tolerated only by the coverage pass), 2 = blocker."""
    out = []
    for n in names:
        out.append(1 if n.startswith(OK_EXTRA) else 3 if n.startswith(TREE) else 2)
    return out


def scan_cell(args):
    """Return (cx, cy, free) where free[bx*64+by] = 1 if the 4x4 block is all bare ground."""
    cx, cy, mp = args
    d = open(f"{mp}world_{cx}_{cy}.lotpack", "rb").read()
    h = open(f"{mp}{cx}_{cy}.lotheader", "rb").read()
    n = struct.unpack_from("<i", h, 8)[0]; p = 12; names = []
    for _ in range(n):
        e = h.index(b"\n", p); names.append(h[p:e].decode()); p = e + 1
    cls = classify_names(names)
    natfirst = [nm.startswith("blends_natural_01") for nm in names]
    offs = struct.unpack_from("<1024q", d, 12)
    cnt = bytearray(64 * 64); cnt2 = bytearray(64 * 64); trees = bytearray(64 * 64); rich2 = bytearray(64 * 64)
    rich = bytearray(64 * 64)  # block has at least one multi-tile square (hand-painted ground)
    for ci in range(1024):
        a = offs[ci]; b = offs[ci + 1] if ci < 1023 else len(d)
        sq = []; p = a
        while p < b:
            k = struct.unpack_from("<i", d, p)[0]; p += 4
            if k == -1:
                sq.extend([None] * struct.unpack_from("<i", d, p)[0]); p += 4
            else:
                p += 4  # room id (unreliable: malls have room -1), floors are checked instead
                sq.append(struct.unpack_from(f"<{k - 1}i", d, p)); p += 4 * (k - 1)
        L = len(sq) // 64
        chx, chy = divmod(ci, 32)
        for s in range(64):
            ok = False; bad = False; multi = False; tree = False
            for z in range(L):
                t = sq[z * 64 + s]
                if not t:
                    continue
                if natfirst[t[0]] and all(cls[i] != 2 for i in t):
                    ok = True; multi = len(t) > 1
                    if any(cls[i] == 3 for i in t): tree = True
                else:
                    bad = True; break
            if ok and not bad:
                sx, sy = divmod(s, 8)
                bi = (chx * 2 + sx // 4) * 64 + chy * 2 + sy // 4
                cnt2[bi] += 1; trees[bi] += tree
                if multi: rich2[bi] = 1
                if not tree:
                    cnt[bi] += 1
                    if multi: rich[bi] = 1
    # ponytail: blocks of 16 single-tile squares are unpainted filler terrain (real ground always has
    # blend overlays), so they are rejected; this also drops genuinely bare lawns/pitches
    # second array: tree squares per block (0..16) where the block is tree-tolerant ground, else 255
    return (cx, cy, bytes(1 if c == 16 and r else 0 for c, r in zip(cnt, rich)),
            bytes(t if c == 16 and r else 255 for c, r, t in zip(cnt2, rich2, trees)))


def lotpack_free(mp, workers):
    cells = [(int(m[0]), int(m[1]), mp) for m in
             (os.path.basename(f)[6:-8].split("_") for f in glob.glob(mp + "world_*_*.lotpack"))]
    free = bytearray(NX * NY); tr = bytearray(b"\xff" * (NX * NY))
    with Pool(workers) as pool:
        for i, (cx, cy, fr, ft) in enumerate(pool.imap_unordered(scan_cell, cells, chunksize=4)):
            for bx in range(64):
                j0 = bx * 64
                row = cx * 64 + bx
                for by in range(64):
                    k = (cy * 64 + by) * NX + row
                    if fr[j0 + by]:
                        free[k] = 1
                    tr[k] = ft[j0 + by]
            if i % 500 == 0:
                log(f"  lotpack {i}/{len(cells)}")
    return free, tr, {(c[0], c[1]) for c in cells}


# ------------------------------------------------------------ distance + pick
def chamfer(blocked):
    """3-4 chamfer distance (units of 1/3 grid cell) to the nearest blocked cell; border = blocked."""
    W = NX + 2
    d = [array.array("B", [0]) * W]
    for j in range(NY):
        row = array.array("B", [0]) * W
        base = j * NX
        for i in range(NX):
            if not blocked[base + i]:
                row[i + 1] = 250
        d.append(row)
    d.append(array.array("B", [0]) * W)
    for j in range(1, NY + 1):
        cur = d[j]; up = d[j - 1]
        for i in range(1, W - 1):
            v = cur[i]
            if v:
                m = min(cur[i - 1] + 3, up[i] + 3, up[i - 1] + 4, up[i + 1] + 4)
                if m < v: cur[i] = m
    for j in range(NY, 0, -1):
        cur = d[j]; dn = d[j + 1]
        for i in range(W - 2, 0, -1):
            v = cur[i]
            if v:
                m = min(cur[i + 1] + 3, dn[i] + 3, dn[i + 1] + 4, dn[i - 1] + 4)
                if m < v: cur[i] = m
    return d


def radius(v):
    """Clear radius in tiles. v/3 cells to blocked-cell centre; -0.5 cell to its edge; chamfer
    overestimates up to ~6% so shave 6%; -1 tile slack."""
    return int(((v / 3.0) - 0.5) * G * 0.94 - 1)


def cands(d, thr_r):
    out = []
    for j in range(NY):
        row = d[j + 1]
        for i in range(NX):
            v = row[i + 1]
            if v > 12 and radius(v) >= thr_r:
                out.append((radius(v), i * G + G // 2, j * G + G // 2))
    return out


B = 160  # spatial hash bucket, >= every spacing used


class Sites:
    def __init__(self):
        self.l = []; self.h = {}

    def near(self, x, y, s):
        bx, by = x // B, y // B
        return any((x - sx) ** 2 + (y - sy) ** 2 < s * s
                   for ax in (-1, 0, 1) for ay in (-1, 0, 1) for sx, sy in self.h.get((bx + ax, by + ay), ()))

    def add(self, r, x, y, t=False):
        self.l.append((x, y, min(r, CAP_R), t)); self.h.setdefault((x // B, y // B), []).append((x, y))


def pick(c, towns, cap, seed=17):
    rnd = random.Random(seed)
    c = [(min(r, 40), rnd.random(), r, x, y) for r, x, y in c]
    c.sort(reverse=True)
    S = Sites(); town_sites = 0
    for name, tx, ty in towns:  # reserve 4 sites 50..700 tiles from each town, 120 apart
        mine = []
        for _, _, r, x, y in c:
            dd = ((x - tx) ** 2 + (y - ty) ** 2) ** .5
            if 50 <= dd <= 700 and all((x - a) ** 2 + (y - b) ** 2 >= 120 ** 2 for a, b in mine):
                mine.append((x, y)); S.add(r, x, y); town_sites += 1
                if len(mine) == 4: break
    # planes first (at most 70% of the cap), then heli-only fields so small clearings are covered too
    for _, _, r, x, y in c:
        if len(S.l) >= cap * 7 // 10: break
        if r >= PLANE_R and not S.near(x, y, PLANE_SPACING): S.add(r, x, y)
    for _, _, r, x, y in c:
        if len(S.l) >= cap: break
        if r < PLANE_R and not S.near(x, y, HELI_SPACING): S.add(r, x, y)
    return S, town_sites


def tree_frac(tr, r, x, y):
    """Fraction of squares in the circle that hold a tree/bush (from per-block tree counts)."""
    cr = max(1, r // G); ci, cj = x // G, y // G; n = t = 0
    for j in range(cj - cr, cj + cr + 1):
        for i in range(ci - cr, ci + cr + 1):
            if (i - ci) ** 2 + (j - cj) ** 2 <= cr * cr and 0 <= i < NX and 0 <= j < NY:
                v = tr[j * NX + i]; n += 16; t += 16 if v == 255 else v
    return t / n if n else 1.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default=MAP)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "..", "ServerEventManager", "Contents", "mods",
                    "ServerEventManager", "42", "media", "lua", "shared", "SEM", "CrashSites.lua"))
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    mp = a.map if a.map.endswith("/") else a.map + "/"
    t0 = time.time()
    g = bytearray(NX * NY)
    towns = []
    log("worldmap.xml"); n1 = raster_xml(g, mp + "worldmap.xml", towns)
    log("zones"); zc = raster_zones(g, mp + "objects.lua")
    log("worldmap-forest.xml (slow)"); n2 = raster_xml(g, mp + "worldmap-forest.xml")
    log(f"S1 features {n1}+{n2}, zones {zc}, towns {towns}")
    s1_blocked = bytes(g)
    log("lotpack scan"); free, tr, present = lotpack_free(mp, a.workers)
    for i in range(NX * NY):  # void / dirty cells block
        if not free[i]: g[i] = 1
    log("distance S1"); d1 = chamfer(s1_blocked); c1 = [c for c in cands(d1, HELI_R) if (c[1] // CELL, c[2] // CELL) in present]; del d1  # S1 knows no void, so only count cells with a lotpack
    log("distance S2"); d2 = chamfer(g)
    c2 = cands(d2, HELI_R); del d2
    s1set = {(x, y) for _, x, y in c1}
    kept = sum(1 for _, x, y in c2 if (x, y) in s1set)
    log(f"S1 cells r>={HELI_R}: {len(c1)}; S2: {len(c2)} ({kept} also in S1; lotpack rejected {len(c1) - kept})")
    # tree-tolerant grid for the coverage pass: no forest polygons / forest zones, trees allowed
    g2 = bytearray(NX * NY); raster_xml(g2, mp + "worldmap.xml"); raster_zones(g2, mp + "objects.lua", ZONE_BLOCK - RELAX_SKIP)
    for i in range(NX * NY):
        if tr[i] == 255: g2[i] = 1
    log("distance relaxed"); d3 = chamfer(g2); c3 = cands(d3, HELI_R); del d3
    blocks = {}
    for cx, cy in present:  # 600-tile blocks that overlap a lotpack cell
        for bx in range(cx * CELL // BLOCK, ((cx + 1) * CELL - 1) // BLOCK + 1):
            for by in range(cy * CELL // BLOCK, ((cy + 1) * CELL - 1) // BLOCK + 1):
                blocks[(bx, by)] = []
    for r, x, y in c3:
        if (x // BLOCK, y // BLOCK) in blocks: blocks[(x // BLOCK, y // BLOCK)].append((min(r, 40), r, x, y))
    S, tsites = pick(c2, towns, MAX_SITES - len(blocks))
    nstrict = len(S.l); rnd = random.Random(5); covered = empty = 0
    for key, lst in sorted(blocks.items()):
        if any(x // BLOCK == key[0] and y // BLOCK == key[1] for x, y, _, _ in S.l): covered += 1; continue
        if not lst: empty += 1; continue
        lst.sort(key=lambda v: (-v[0], rnd.random()))
        for _, r, x, y in lst[:300]:
            if tree_frac(tr, r, x, y) <= TREE_MAX:
                S.add(r, x, y, True); break
        else: empty += 1
    sites = sorted(S.l)
    ntree = len(sites) - nstrict
    log(f"blocks {len(blocks)}: {covered} already had a strict site, {ntree} tree-tolerant picks, {empty} without any usable r>={HELI_R} site")
    out = []
    for x, y, r, t in sites:
        out.append(f'  {{x={x}, y={y}, r={r}, k="{"plane" if r >= PLANE_R else "heli"}"{", t=true" if t else ""}}},')
    npl = sum(1 for s in sites if s[2] >= PLANE_R)
    hdr = (f"-- Generated by tools/find-crash-sites.py from the vanilla Muldraugh, KY map on "
           f"{datetime.date.today()}. Do not edit by hand.\n"
           f"-- {len(sites)} sites: {npl} plane (r >= {PLANE_R}), {len(sites) - npl} heli (r >= {HELI_R}); "
           f"{nstrict} strict, {ntree} with t=true (coverage picks, up to {int(TREE_MAX * 100)}% tree squares; Crash knocks the trees down); "
           f"{tsites} reserved near towns.\n"
           f"-- r = clear radius in tiles (no building, road, water, forest zone, tree, fence or non-natural floor; t=true entries may hold trees).\n"
           f"-- Regenerate: python tools/find-crash-sites.py [--map \"<game>/media/maps/Muldraugh, KY\"]\n"
           f"-- k = largest aircraft that fits. Trees planted at load by erosion zones may still appear; Crash clears them.\n")
    with open(a.out, "w", newline="\n") as f:
        f.write(hdr + "return {\n" + "\n".join(out) + "\n}\n")
    log(f"wrote {a.out}: {len(sites)} sites ({npl} plane, {len(sites) - npl} heli) in {time.time() - t0:.0f}s")
    print("S1c", len(c1), "S2c", len(c2), "kept", kept, "nstrict", nstrict, "tree", ntree, "blocks", len(blocks), "covered", covered, "empty", empty)


if __name__ == "__main__":
    main()
