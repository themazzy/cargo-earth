"""Writes the Cargo Earth dash phone part for a car model: jbeam, materials and the click grid's input actions.

python tools/make-dash-phone.py

For each car in CARS it writes mod/cargo_earth/vehicles/<model>/cargo_earth_phone.jbeam (+ the mesh and materials next
to it), and once mod/cargo_earth/vehicles/common/cargo_earth_phone/cargo_earth_phone.interaction.json.

The part ("Cargo Earth phone holder") goes in an empty slot of the car and adds no nodes: the phone mesh is a flexbody
on the dashboard's own node group, and the click grid is COLS x ROWS of the car's cockpit triggers ("triggers2", the
same kind as its hazard switch) over the screen, framed on three dashboard nodes. A trigger's frame: x toward idX, y
toward idY, z = x cross y (read off the Pigeon's own dash switches). Each cell runs input action cargoEarthTap_<c>_<r>,
which asks the part's controller (lua/vehicle/controller/cargoEarthPhone.lua) to click that spot of the page.

Positions are jbeam coordinates: the car faces -y, z is up, +x is the driver's left when looking forward.
"""
import json
import os
import shutil

ROOT = os.path.join(os.path.dirname(__file__), '..', 'mod', 'cargo_earth', 'vehicles')
COLS, ROWS = 6, 12
SCREEN_W, SCREEN_H = 0.100, 0.100 * 560 / 290   # must match tools/make-phone-mesh.py
DEPTH = 0.02                                      # how thick each click box is

CARS = {
    'pigeon': {
        'slotType': 'pigeon_mod',
        'group': 'pigeon_dash',
        # dashboard nodes: (name, position)
        'ref': ('dsh2', (-0.316, -0.457, 0.87)),
        'x': ('dsh2l', (-0.012, -0.457, 0.87)),
        'y': ('dsh1', (-0.316, -0.457, 0.99)),
        # the middle of the screen: on the centre of the dash, standing on its top, a little toward the driver
        'centre': (0.0, -0.43, 1.11),
    },
}


def sub(a, b): return tuple(a[i] - b[i] for i in range(3))
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def unit(a):
    n = dot(a, a) ** 0.5
    return tuple(v / n for v in a)


def frame(car):
    o = car['ref'][1]
    x = unit(sub(car['x'][1], o))
    y0 = sub(car['y'][1], o)
    y = unit(sub(y0, tuple(x[i] * dot(y0, x) for i in range(3))))
    return o, x, y, cross(x, y)


def local(car, p):
    o, x, y, z = frame(car)
    d = sub(p, o)
    return {'x': round(dot(d, x), 4), 'y': round(dot(d, y), 4), 'z': round(dot(d, z), 4)}


def cell_centre(car, col, row):
    cx, cy, cz = car['centre']
    cw, ch = SCREEN_W / COLS, SCREEN_H / ROWS
    # seen by the driver, +x is on the left: the page's left edge (column 1) is at +x
    return (cx + SCREEN_W / 2 - (col - 0.5) * cw, cy + 0.004, cz + SCREEN_H / 2 - (row - 0.5) * ch)


def action(col, row): return 'cargoEarthTap_%d_%d' % (col, row)


def part(model, car):
    o, x, y, z = frame(car)
    cw, ch = SCREEN_W / COLS * 0.98, SCREEN_H / ROWS * 0.98
    # box size in the trigger's frame: its x and y axes lie in the screen when the frame's x and y do (dash nodes
    # across and up); its z is the screen's normal
    size = {'x': round(cw, 4), 'y': round(ch, 4), 'z': DEPTH}
    triggers = [['id', 'idRef:', 'idX:', 'idY:', 'type', 'size', 'baseRotation', 'rotation', 'translation', 'baseTranslation']]
    links = [['triggerId:triggers2', 'triggerInput', 'inputAction']]
    for row in range(1, ROWS + 1):
        for col in range(1, COLS + 1):
            tid = 'cep_%d_%d' % (col, row)
            triggers.append([tid, car['ref'][0], car['x'][0], car['y'][0], 'box', size,
                             {'x': 0, 'y': 0, 'z': 0}, {'x': 0, 'y': 0, 'z': 0}, {'x': 0, 'y': 0, 'z': 0},
                             local(car, cell_centre(car, col, row)), {'color': [0.91, 0.27, 0.17, 0.6]}])
            links.append([tid, 'action0', action(col, row)])
    name = 'cargo_earth_phone_' + model
    return {name: {
        'information': {'authors': 'Cargo Earth', 'name': 'Cargo Earth phone holder', 'value': 40},
        'slotType': car['slotType'],
        'flexbodies': [
            ['mesh', '[group]:', 'nonFlexMaterials'],
            ['cargo_earth_phone_body', [car['group']], [], {'pos': dict(zip('xyz', car['centre']))}],
            ['cargo_earth_phone_screen', [car['group']], [], {'pos': dict(zip('xyz', car['centre']))}],
        ],
        'controller': [
            ['fileName'],
            ['cargoEarthPhone', {'webViewTag': '@cargo_earth_phone', 'cols': COLS, 'rows': ROWS,
                                 'width': 580, 'height': 1120, 'fps': 15}],
        ],
        'triggers2': triggers,
        'triggerEventLinks2': links,
    }}


MATERIALS = {
    'cargo_earth_phone_screen': {
        'name': 'cargo_earth_phone_screen', 'mapTo': 'cargo_earth_phone_screen', 'class': 'Material',
        'Stages': [{'baseColorMap': '@cargo_earth_phone', 'emissiveMap': '@cargo_earth_phone',
                    'emissiveFactor': [1, 1, 1], 'roughnessFactor': 0.35, 'metallicFactor': 0}, {}, {}, {}],
        'materialTag0': 'beamng', 'materialTag1': 'vehicle', 'version': 1.5,
    },
    'cargo_earth_phone_body': {
        'name': 'cargo_earth_phone_body', 'mapTo': 'cargo_earth_phone_body', 'class': 'Material',
        'Stages': [{'baseColorFactor': [0.06, 0.06, 0.055, 1], 'roughnessFactor': 0.55, 'metallicFactor': 0}, {}, {}, {}],
        'materialTag0': 'beamng', 'materialTag1': 'vehicle', 'version': 1.5,
    },
}


def interaction():
    actions = {}
    for row in range(1, ROWS + 1):
        for col in range(1, COLS + 1):
            actions[action(col, row)] = {
                'title': 'Phone', 'ctx': 'vlua', 'cat': 'vehicle_specific',
                'onDown': 'controller.getControllerSafe("cargoEarthPhone").tap(%d, %d)' % (col, row),
            }
    return {'fileversion': 2, 'actions': actions}


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1)
        f.write('\n')


def main():
    common = os.path.join(ROOT, 'common', 'cargo_earth_phone')
    write_json(os.path.join(common, 'cargo_earth_phone.interaction.json'), interaction())
    for model, car in CARS.items():
        d = os.path.join(ROOT, model)
        write_json(os.path.join(d, 'cargo_earth_phone.jbeam'), part(model, car))
        write_json(os.path.join(d, 'cargo_earth_phone.materials.json'), MATERIALS)
        shutil.copyfile(os.path.join(common, 'cargo_earth_phone.dae'), os.path.join(d, 'cargo_earth_phone.dae'))
        print(model, 'triggers', COLS * ROWS)


if __name__ == '__main__':
    main()
