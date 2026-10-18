"""Builds the viddeo wordmark + app icon as flat SVG paths.

Run: uv run --with shapely python brand/build_logo.py

Concept: letters are blue, transport controls are ink, record is red.
  ▶ play triangle leads the "v"
  ❚❚ the two "d" stems form the pause bars
  ● the "o" is the record button
"""

from pathlib import Path

from shapely import affinity
from shapely.geometry import MultiPolygon, Point, Polygon, box
from shapely.ops import unary_union

OUT = Path(__file__).parent / "logo"

# --- grid ------------------------------------------------------------------
BASE = 200.0  # baseline
XH = 100.0  # x-height top
ASC = 52.0  # ascender top (d stems / i dot)
MID = (BASE + XH) / 2
W = 27.0  # stem weight
OV = 2.5  # optical overshoot for rounds
R_SOFT = 3.0  # corner softening applied everywhere
ARM_SLOPE = 0.85  # dx/dy shared by the v's left arm and the play's top edge
V_RIGHT_SLOPE = None  # None = symmetric v; a smaller value steepens the right arm
E_APERTURE = 38  # degrees below the bar where the e terminal is cut
Q = 96  # circle resolution
ICON_MARK_WIDTH = 400  # width of ▶v inside the 512 icon

ROLES = {"letter": "letter", "play": "control", "pause": "control", "rec": "rec"}

PALETTE = {
    "light": {"letter": "#2563FF", "control": "#0D1321", "rec": "#FF3B3B"},
    "dark": {"letter": "#5B8CFF", "control": "#F4F6FB", "rec": "#FF4747"},
    "mono-dark": {"letter": "#0D1321", "control": "#0D1321", "rec": "#0D1321"},
    "mono-light": {"letter": "#FFFFFF", "control": "#FFFFFF", "rec": "#FFFFFF"},
}


def circle(cx, cy, r):
    return Point(cx, cy).buffer(r, quad_segs=Q)


def soften(g, convex=R_SOFT, concave=R_SOFT):
    if convex:
        g = g.buffer(-convex, quad_segs=Q).buffer(convex, quad_segs=Q)
    if concave:
        g = g.buffer(concave, quad_segs=Q).buffer(-concave, quad_segs=Q)
    return g


def fit_height(g, top, bottom):
    minx, miny, maxx, maxy = g.bounds
    s = (bottom - top) / (maxy - miny)
    g = affinity.scale(g, s, s, origin=(minx, miny))
    minx, miny, _, _ = g.bounds
    return affinity.translate(g, -minx, top - miny)


# --- glyphs (each built at x=0, returned as list of (role, geometry)) --------


def g_play():
    # top edge runs parallel to the v's left arm: (width / half-height) == ARM_SLOPE
    h = BASE - XH
    tri = Polygon([(0, 0), (0, h), (ARM_SLOPE * h / 2, h / 2)])
    tri = soften(tri, convex=5, concave=0)
    # triangles need more overshoot than circles to look the same height
    return [("play", fit_height(tri, XH - 1, BASE + 1))]


def g_v():
    foot = 18.0
    h = BASE - XH
    sl, sr = ARM_SLOPE, V_RIGHT_SLOPE or ARM_SLOPE
    run_l, run_r = sl * h, sr * h
    width = run_l + foot + run_r
    # horizontal stroke widths that give each arm a perpendicular weight of W
    wl, wr = W * (1 + sl**2) ** 0.5, W * (1 + sr**2) ** 0.5
    d = (width - wl - wr) / (sl + sr)
    v = Polygon(
        [
            (0, XH),
            (wl, XH),
            (wl + sl * d, XH + d),
            (width - wr, XH),
            (width, XH),
            (run_l + foot, BASE),
            (run_l, BASE),
        ]
    )
    return [("letter", soften(v))]


def g_i():
    stem = soften(box(0, XH, W, BASE))
    dot_r = W * 0.6
    dot = circle(W / 2, ASC + dot_r, dot_r)
    return [("letter", unary_union([stem, dot]))]


def g_d():
    r = (BASE - XH) / 2 + OV
    counter_r = r - W
    # the stem replaces the bowl's right wall and closes the counter
    stem_x = r + counter_r
    stem = soften(box(stem_x, ASC, stem_x + W, BASE))
    ring = circle(r, MID, r).difference(circle(r, MID, counter_r))
    # cut under the stem (not at its edge) so softening never notches the seam
    bowl = soften(ring.difference(box(stem_x + W / 2, 0, stem_x + 2 * r, 400)), concave=0)
    bowl = bowl.difference(stem)
    return [("letter", bowl), ("pause", stem)]


def g_e():
    r = (BASE - XH) / 2 + OV
    cx = r
    ring = circle(cx, MID, r).difference(circle(cx, MID, r - W))
    bar_h = W * 0.64
    bar_top = MID - bar_h / 2 + 1
    bar = box(cx - r + W / 2, bar_top, cx + r, bar_top + bar_h)
    e = unary_union([ring, bar]).intersection(circle(cx, MID, r))
    # aperture: radial wedge opening the lower right
    ay = bar_top + bar_h
    import math

    t = math.tan(math.radians(E_APERTURE))
    wedge = Polygon([(cx, ay), (cx + 2 * r, ay), (cx + 2 * r, ay + t * 2 * r)])
    e = e.difference(wedge)
    return [("letter", soften(e))]


def g_o():
    r = (BASE - XH) / 2 + OV
    return [("rec", circle(r, MID, r))]


# --- layout ------------------------------------------------------------------

# (glyph, minimum distance to the previous glyph's ink)
SEQUENCE = [
    (g_play, 0),
    (g_v, 13),
    (g_i, 10),
    (g_d, 12),
    (g_d, 13),
    (g_e, 11),
    (g_o, 10),
]


def union_of(parts):
    return unary_union([g for _, g in parts])


def place_after(prev, parts, distance):
    """Slide `parts` right until its ink is exactly `distance` from `prev`."""
    shape = union_of(parts)
    lo, hi = prev.bounds[0] - shape.bounds[2], prev.bounds[2] + distance + 1
    for _ in range(60):
        mid = (lo + hi) / 2
        d = affinity.translate(shape, mid).distance(prev)
        if d < distance:
            lo = mid
        else:
            hi = mid
    return [(role, affinity.translate(g, hi)) for role, g in parts]


def build_wordmark():
    placed = []
    prev = None
    for fn, dist in SEQUENCE:
        parts = fn()
        if prev is not None:
            parts = place_after(prev, parts, dist)
        placed.extend(parts)
        prev = union_of(parts)
    return placed


# --- svg output --------------------------------------------------------------


def path_d(geom):
    polys = geom.geoms if isinstance(geom, MultiPolygon) else [geom]
    out = []
    for p in polys:
        p = p.simplify(0.03)
        for ring in [p.exterior, *p.interiors]:
            pts = list(ring.coords)[:-1]
            out.append(
                "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"
            )
    return "".join(out)


def svg(parts, palette, pad=0.0, bg=None, title="viddeo"):
    allg = union_of(parts)
    minx, miny, maxx, maxy = allg.bounds
    minx, miny, maxx, maxy = minx - pad, miny - pad, maxx + pad, maxy + pad
    w, h = maxx - minx, maxy - miny
    body = []
    if bg:
        body.append(bg(minx, miny, w, h))
    by_role = {}
    for role, g in parts:
        by_role.setdefault(role, []).append(g)
    for role, color in ROLES.items():
        if role in by_role:
            body.append(
                f'<path class="{role}" fill="{palette[color]}" fill-rule="evenodd" '
                f'd="{path_d(unary_union(by_role[role]))}"/>'
            )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{minx:.2f} {miny:.2f} {w:.2f} {h:.2f}" '
        f'role="img" aria-label="{title}"><title>{title}</title>' + "".join(body) + "</svg>\n"
    )


def build_icon():
    """App icon: ▶ + v monogram on an ink squircle, with a red REC dot."""
    play = g_play()
    v = place_after(union_of(play), g_v(), 11)
    parts = play + v
    vminx, vminy, vmaxx, _ = union_of(v).bounds
    rec_r = 20
    parts.append(("rec", circle(vmaxx - rec_r, vminy - rec_r - 16, rec_r)))
    size = 512
    shape = union_of(parts)
    minx, miny, maxx, maxy = shape.bounds
    scale = ICON_MARK_WIDTH / (maxx - minx)
    parts = [
        (role, affinity.scale(g, scale, scale, origin=(minx, miny))) for role, g in parts
    ]
    # center the whole group (mark + REC dot) in the squircle
    minx, miny, maxx, maxy = union_of(parts).bounds
    dx = (size - (maxx - minx)) / 2 - minx
    dy = (size - (maxy - miny)) / 2 - miny
    parts = [(role, affinity.translate(g, dx, dy)) for role, g in parts]
    return parts, size


def squircle_path(size, inset=0):
    # Apple-style continuous corner approximated with a superellipse (n=5)
    import math

    n, a = 5, size / 2 - inset
    pts = []
    for i in range(360):
        t = 2 * math.pi * i / 360
        c, s = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(c) ** (2 / n), c) + size / 2
        y = a * math.copysign(abs(s) ** (2 / n), s) + size / 2
        pts.append(f"{x:.2f} {y:.2f}")
    return "M" + " L".join(pts) + "Z"


def icon_svg(parts, size, palette, bg):
    top, bottom = bg
    body = [
        f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/>'
        f"</linearGradient></defs>",
        f'<path fill="url(#bg)" d="{squircle_path(size)}"/>',
    ]
    for role, color in ROLES.items():
        gs = [g for r, g in parts if r == role]
        if gs:
            body.append(
                f'<path class="{role}" fill="{palette[color]}" d="{path_d(unary_union(gs))}"/>'
            )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" role="img" '
        f'aria-label="viddeo"><title>viddeo</title>' + "".join(body) + "</svg>\n"
    )


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    word = build_wordmark()
    files = {
        "viddeo-logo.svg": svg(word, PALETTE["light"]),
        "viddeo-logo-dark.svg": svg(word, PALETTE["dark"]),
        "viddeo-logo-mono.svg": svg(word, PALETTE["mono-dark"]),
        "viddeo-logo-mono-white.svg": svg(word, PALETTE["mono-light"]),
    }
    icon, size = build_icon()
    files["viddeo-icon.svg"] = icon_svg(icon, size, PALETTE["dark"], ("#1A2236", "#0B0F1A"))
    files["viddeo-icon-light.svg"] = icon_svg(icon, size, PALETTE["light"], ("#FFFFFF", "#EEF2FA"))
    for name, content in files.items():
        (OUT / name).write_text(content)
        print("wrote", OUT / name)

    sheet = (OUT.parent / "sheet.template.html").read_text()
    sheet = sheet.replace("{{LOGO_LIGHT}}", files["viddeo-logo.svg"].strip())
    (OUT.parent / "index.html").write_text(sheet)
    print("wrote", OUT.parent / "index.html")

    export_pngs(files)


CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PNG_EXPORTS = [
    ("viddeo-logo.svg", 2400),
    ("viddeo-logo-dark.svg", 2400),
    ("viddeo-logo-mono.svg", 2400),
    ("viddeo-logo-mono-white.svg", 2400),
    ("viddeo-icon.svg", 1024),
    ("viddeo-icon.svg", 512),
    ("viddeo-icon.svg", 180),
    ("viddeo-icon.svg", 32),
    ("viddeo-icon-light.svg", 1024),
]


def export_pngs(files):
    """Rasterise with headless Chrome (transparent background)."""
    import re
    import subprocess
    import tempfile

    if not Path(CHROME).exists():
        print("Chrome not found; skipping PNG export")
        return
    png_dir = OUT / "png"
    png_dir.mkdir(exist_ok=True)
    for name, width in PNG_EXPORTS:
        _, _, vw, vh = map(float, re.search(r'viewBox="([^"]+)"', files[name]).group(1).split())
        height = round(width * vh / vw)
        out = png_dir / f"{Path(name).stem}-{width}.png"
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
            f.write(
                "<html><body style='margin:0;background:transparent'>"
                f"<img src='{(OUT / name).as_uri()}' style='display:block;width:{width}px;height:{height}px'>"
                "</body></html>"
            )
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--default-background-color=00000000", f"--screenshot={out}",
             f"--window-size={width},{height}", Path(f.name).as_uri()],
            check=True, capture_output=True,
        )
        print("wrote", out)


if __name__ == "__main__":
    main()
