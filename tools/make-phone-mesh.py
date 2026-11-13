"""Writes the dash phone mesh (COLLADA) for the Cargo Earth phone part.

Used by tools/make-dash-phone.py: write(path, turns) writes the phone turned by each yaw in `turns` (degrees about
the vertical axis through the middle of its screen; positive turns its face from +y toward -x), named
cargo_earth_phone_body<suffix> and cargo_earth_phone_screen<suffix>. The game picks the turn that faces the driver's
head in each car (lua/ge/extensions/cargoEarth/dash.lua, meshSuffix).

Two meshes, in metres, centred on the middle of the screen, in jbeam axes (the car faces -y, z is up):
  cargo_earth_phone_body    the phone's dark case, a flat box behind the screen
  cargo_earth_phone_screen  the screen, a quad facing the driver (+y), UV 0..1 over the whole page
The screen keeps the phone app's 290 x 560 shape.
"""
import os

SCREEN_W, SCREEN_H = 0.100, 0.100 * 560 / 290
RIM, DEPTH = 0.006, 0.012
import math


def box(w, h, d, y0):
    """a box w (x) by d (y) by h (z), its front face at y = y0, as (positions, normals, triangles)"""
    x0, x1, z0, z1, ya, yb = -w / 2, w / 2, -h / 2, h / 2, y0 - d, y0
    faces = [  # 4 corners each, counter-clockwise seen from outside, and the normal
        ([(x0, yb, z0), (x1, yb, z0), (x1, yb, z1), (x0, yb, z1)], (0, 1, 0)),
        ([(x1, ya, z0), (x0, ya, z0), (x0, ya, z1), (x1, ya, z1)], (0, -1, 0)),
        ([(x0, ya, z0), (x0, yb, z0), (x0, yb, z1), (x0, ya, z1)], (-1, 0, 0)),
        ([(x1, yb, z0), (x1, ya, z0), (x1, ya, z1), (x1, yb, z1)], (1, 0, 0)),
        ([(x0, ya, z1), (x0, yb, z1), (x1, yb, z1), (x1, ya, z1)], (0, 0, 1)),
        ([(x0, yb, z0), (x0, ya, z0), (x1, ya, z0), (x1, yb, z0)], (0, 0, -1)),
    ]
    pos, nor, tris = [], [], []
    for corners, n in faces:
        a, b, c = corners[0], corners[1], corners[2]
        u = [b[i] - a[i] for i in range(3)]
        v = [c[i] - a[i] for i in range(3)]
        cr = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        if sum(cr[i] * n[i] for i in range(3)) < 0:  # wind every face counter-clockwise seen from outside
            corners = corners[::-1]
        base = len(pos)
        pos += corners
        nor += [n] * 4
        tris += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    return pos, nor, tris


def flat(rows):
    return ' '.join('%.5f' % v for row in rows for v in row)


def geometry(name, material, pos, nor, uv, tris):
    p = ' '.join('%d %d %d' % (i, i, i) for t in tris for i in t)
    return f'''
    <geometry id="{name}-mesh" name="{name}"><mesh>
      <source id="{name}-pos"><float_array id="{name}-pos-a" count="{len(pos) * 3}">{flat(pos)}</float_array>
        <technique_common><accessor source="#{name}-pos-a" count="{len(pos)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
      <source id="{name}-nor"><float_array id="{name}-nor-a" count="{len(nor) * 3}">{flat(nor)}</float_array>
        <technique_common><accessor source="#{name}-nor-a" count="{len(nor)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
      <source id="{name}-uv"><float_array id="{name}-uv-a" count="{len(uv) * 2}">{flat(uv)}</float_array>
        <technique_common><accessor source="#{name}-uv-a" count="{len(uv)}" stride="2"><param name="S" type="float"/><param name="T" type="float"/></accessor></technique_common></source>
      <vertices id="{name}-vtx"><input semantic="POSITION" source="#{name}-pos"/></vertices>
      <triangles material="{material}" count="{len(tris)}">
        <input semantic="VERTEX" source="#{name}-vtx" offset="0"/><input semantic="NORMAL" source="#{name}-nor" offset="1"/><input semantic="TEXCOORD" source="#{name}-uv" offset="2" set="0"/>
        <p>{p}</p></triangles>
    </mesh></geometry>'''


def node(name, material):
    return f'''
      <node id="{name}" name="{name}" type="NODE"><instance_geometry url="#{name}-mesh" name="{name}"><bind_material><technique_common>
        <instance_material symbol="{material}" target="#{material}-material"/></technique_common></bind_material></instance_geometry></node>'''


def turn(points, yaw):
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return [(x * c - y * s, x * s + y * c, z) for x, y, z in points]


def meshes(suffix='', yaw=0.0):
    """(geometries, nodes) COLLADA text for the phone turned by yaw, its meshes named with suffix"""
    bpos, bnor, btris = box(SCREEN_W + 2 * RIM, SCREEN_H + 2 * RIM, DEPTH, -0.0005)
    buv = [(0, 0)] * len(bpos)
    w, h, y = SCREEN_W / 2, SCREEN_H / 2, 0.0
    # seen by the driver (looking toward -y), +x is on the left: the page's left edge (u = 0) goes there
    spos = [(w, y, -h), (-w, y, -h), (-w, y, h), (w, y, h)]
    snor = [(0, 1, 0)] * 4
    suv = [(0, 0), (1, 0), (1, 1), (0, 1)]
    stris = [(0, 1, 2), (0, 2, 3)]
    bpos, bnor, spos, snor = turn(bpos, yaw), turn(bnor, yaw), turn(spos, yaw), turn(snor, yaw)
    body, screen = MATS[0] + suffix, MATS[1] + suffix
    return (geometry(body, MATS[0], bpos, bnor, buv, btris) + geometry(screen, MATS[1], spos, snor, suv, stris),
            node(body, MATS[0]) + node(screen, MATS[1]))


MATS = ['cargo_earth_phone_body', 'cargo_earth_phone_screen']


def write(path, turns):
    """one COLLADA file with the phone turned every way in `turns`: a list of (suffix, yaw)"""
    geos, nodes = '', ''
    for suffix, yaw in turns:
        g, n = meshes(suffix, yaw)
        geos, nodes = geos + g, nodes + n
    doc = f'''<?xml version="1.0" encoding="utf-8"?>
<!-- generated by tools/make-phone-mesh.py -->
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
  <asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>
  <library_effects>{''.join(f'<effect id="{m}-effect"><profile_COMMON><technique sid="common"><lambert/></technique></profile_COMMON></effect>' for m in MATS)}</library_effects>
  <library_materials>{''.join(f'<material id="{m}-material" name="{m}"><instance_effect url="#{m}-effect"/></material>' for m in MATS)}</library_materials>
  <library_geometries>{geos}
  </library_geometries>
  <library_visual_scenes><visual_scene id="Scene" name="Scene">{nodes}
  </visual_scene></library_visual_scenes>
  <scene><instance_visual_scene url="#Scene"/></scene>
</COLLADA>
'''
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(doc)
