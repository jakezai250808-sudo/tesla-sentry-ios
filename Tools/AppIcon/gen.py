#!/usr/bin/env python3
"""Generate the Watchpost viewfinder mark as outlined SVG geometry.

Everything is plain filled path data (no strokes), 1024x1024 canvas,
so the SVG renders identically in Icon Composer / CoreSVG.
"""
import json, math, sys, os

K = 0.5522847498307936  # cubic-bezier circle constant for 90-degree arcs


def f(v):
    """Compact number: integers without decimals, else 2 decimals."""
    return f"{v:.0f}" if abs(v - round(v)) < 0.005 else f"{v:.2f}"


def rot(p, s):
    x, y = p
    return (-y, x) if s > 0 else (y, -x)


def rounded_path(pts, radii):
    """Closed polygon through pts (right-angle turns) with per-vertex radii."""
    n = len(pts)
    out = []
    last = None

    def line_to(p):
        nonlocal last
        if last is not None and abs(last[0] - p[0]) < 0.01 and abs(last[1] - p[1]) < 0.01:
            return
        out.append(("M" if last is None else "L") + f"{f(p[0])} {f(p[1])}")
        last = p

    for i in range(n):
        prev, cur, nxt = pts[i - 1], pts[i], pts[(i + 1) % n]
        r = radii[i]
        u = (cur[0] - prev[0], cur[1] - prev[1])
        v = (nxt[0] - cur[0], nxt[1] - cur[1])
        lu = math.hypot(*u); lv = math.hypot(*v)
        u = (u[0] / lu, u[1] / lu); v = (v[0] / lv, v[1] / lv)
        if r <= 0:
            line_to(cur)
            continue
        s = 1 if (u[0] * v[1] - u[1] * v[0]) > 0 else -1
        t1 = (cur[0] - r * u[0], cur[1] - r * u[1])
        t2 = (cur[0] + r * v[0], cur[1] + r * v[1])
        nu = rot(u, s)                      # unit normal towards the arc centre
        o = (t1[0] + r * nu[0], t1[1] + r * nu[1])
        v1 = (t1[0] - o[0], t1[1] - o[1]); v2 = (t2[0] - o[0], t2[1] - o[1])
        l1 = math.hypot(*v1); l2 = math.hypot(*v2)
        d1 = rot((v1[0] / l1, v1[1] / l1), s)   # unit tangent leaving T1
        d2 = rot((v2[0] / l2, v2[1] / l2), s)   # unit tangent arriving at T2
        c1 = (t1[0] + K * r * d1[0], t1[1] + K * r * d1[1])
        c2 = (t2[0] - K * r * d2[0], t2[1] - K * r * d2[1])
        line_to(t1)
        out.append("C" + f"{f(c1[0])} {f(c1[1])} {f(c2[0])} {f(c2[1])} {f(t2[0])} {f(t2[1])}")
        last = t2
    out.append("Z")
    return "".join(out)


def bracket_tl(x0, y0, arm_h, arm_v, w, ro, ri, rc):
    """Top-left L bracket, outer corner at (x0, y0)."""
    pts = [
        (x0, y0),                 # outer corner (convex)
        (x0 + arm_h, y0),         # top arm, outer end
        (x0 + arm_h, y0 + w),     # top arm, inner end
        (x0 + w, y0 + w),         # inner corner (concave)
        (x0 + w, y0 + arm_v),     # left arm, inner end
        (x0, y0 + arm_v),         # left arm, outer end
    ]
    return rounded_path(pts, [ro, rc, rc, ri, rc, rc])


def _tokens(path):
    i = 0
    cur = None
    for j, ch in enumerate(path):
        if ch in "MLCZ":
            if j > i:
                yield cur, [float(t) for t in path[i:j].split()]
            cur = ch
            i = j + 1
            if ch == "Z":
                yield "Z", []
    if i < len(path):
        yield cur, [float(t) for t in path[i:].split()]


def mirror_path(path, fx, fy, c=512.0):
    def tx(x):
        return 2 * c - x if fx else x

    def ty(y):
        return 2 * c - y if fy else y
    res = []
    for cmd, nums in _tokens(path):
        vals = []
        for k in range(0, len(nums), 2):
            vals += [tx(nums[k]), ty(nums[k + 1])]
        res.append(cmd + " ".join(f(v) for v in vals))
    return "".join(res)


def mark(w=84, O=297, arm=227, ro=84, ri=42, rc=42, dot=86):
    """Return the mark as a list of SVG elements (4 bracket paths + 1 dot)."""
    x0 = 512 - O
    tl = bracket_tl(x0, x0, arm, arm, w, ro, ri, rc)
    tr = mirror_path(tl, fx=True, fy=False)
    br = mirror_path(tl, fx=True, fy=True)
    bl = mirror_path(tl, fx=False, fy=True)
    return [f'<path d="{p}"/>' for p in (tl, tr, br, bl)] + [f'<circle cx="512" cy="512" r="{f(dot)}"/>']


def svg(elements, fill="#FFFFFF"):
    head = ("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" "
            "viewBox=\"0 0 1024 1024\">\n")
    comment = ("  <!-- Watchpost mark: four corner brackets around a centred dot.\n"
               "       Plain filled outlines on a 1024 canvas: mark spans 212-812 (58.6 % of canvas),\n"
               "       stroke 92, dot radius 94. Background and effects live in icon.json. -->\n")
    body = "".join("    " + e + "\n" for e in elements)
    return head + comment + f'  <g fill="{fill}">\n' + body + "  </g>\n</svg>\n"


LIGHT = "srgb:0.00000,0.37255,0.80000,1.00000"    # #005FCC primaryFill (light)
DARK = "srgb:0.03922,0.39608,0.85098,1.00000"     # #0A65D9 primaryFill (dark)


def icon_json(glass=False):
    doc = {
        "fill": {"solid": LIGHT},
        "fill-specializations": [{"appearance": "dark", "value": {"solid": DARK}}],
        "groups": [
            {
                "name": "Mark",
                "layers": [
                    {
                        "name": "mark",
                        "image-name": "mark.svg",
                        "glass": glass,
                        "fill-specializations": [{"appearance": "dark", "value": {"solid": DARK}}],
                    }
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.5},
                "specular": True,
            }
        ],
        "supported-platforms": {"squares": ["iOS"]},
    }
    return json.dumps(doc, indent=2, separators=(",", " : "), ensure_ascii=False) + "\n"


def build(outdir, **kw):
    glass = kw.pop("glass", False)
    os.makedirs(os.path.join(outdir, "Assets"), exist_ok=True)
    elements = mark(**kw)
    with open(os.path.join(outdir, "Assets", "mark.svg"), "w") as f:
        f.write(svg(elements))
    with open(os.path.join(outdir, "icon.json"), "w") as f:
        f.write(icon_json(glass))


if __name__ == "__main__":
    outdir = sys.argv[1]
    kw = {}
    for a in sys.argv[2:]:
        k, v = a.split("=")
        kw[k] = (v == "True") if v in ("True", "False") else float(v)
    build(outdir, **kw)
