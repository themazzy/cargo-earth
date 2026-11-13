"""Writes the shared files of the Cargo Earth dash phone, which fits any car.

python tools/make-dash-phone.py

The part itself is not a file: the game side builds it for each car while the car loads
(mod/cargo_earth/lua/ge/extensions/cargoEarth/dash.lua). It needs these, in mod/cargo_earth/vehicles/common/cargo_earth_phone/:
  cargo_earth_phone.dae               the phone mesh, turned every YAW_STEP degrees from -YAW_MAX to YAW_MAX, so each
                                      car uses the turn that faces its driver (names cargo_earth_phone_body_yp30, ..._ym5)
  cargo_earth_phone.materials.json    the case and the screen (the screen shows the vehicle web view @cargo_earth_phone)
  cargo_earth_phone.interaction.json  the click grid's input actions: cell (c, r) runs cargoEarthTap_<c>_<r>, which asks
                                      the part's controller (lua/vehicle/controller/cargoEarthPhone.lua) to click there

Keep COLS, ROWS, YAW_STEP and YAW_MAX the same as in dash.lua.
"""
import json
import os
import importlib.util

ROOT = os.path.join(os.path.dirname(__file__), '..', 'mod', 'cargo_earth', 'vehicles')
COLS, ROWS = 6, 12
YAW_STEP, YAW_MAX = 5, 70


def suffix(yaw): return '_y%s%d' % ('m' if yaw < 0 else 'p', abs(yaw))


def action(col, row): return 'cargoEarthTap_%d_%d' % (col, row)


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


def load_mesh():
    spec = importlib.util.spec_from_file_location('phone_mesh', os.path.join(os.path.dirname(__file__), 'make-phone-mesh.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    common = os.path.join(ROOT, 'common', 'cargo_earth_phone')
    write_json(os.path.join(common, 'cargo_earth_phone.interaction.json'), interaction())
    write_json(os.path.join(common, 'cargo_earth_phone.materials.json'), MATERIALS)
    turns = [(suffix(y), y) for y in range(-YAW_MAX, YAW_MAX + 1, YAW_STEP)]
    load_mesh().write(os.path.join(common, 'cargo_earth_phone.dae'), turns)
    print('phone meshes:', len(turns), 'turns,', COLS * ROWS, 'click cells')


if __name__ == '__main__':
    main()
