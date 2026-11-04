"""Definitions only: alternate soft-stump skinning for the plush locomotion rig.

Call refine_stump_weights(rig) after saving a checkpoint. It changes only the
nine Coat/proxy deformation groups. The baked IK and all bone transforms remain
unchanged. Full Foot weights keep the soles flat; Body-to-Foot translation makes
the short, deep plush stumps stretch softly instead of rotating the belly with
the thigh. No live connection, automatic invocation or file save is included.
"""

import bpy
import numpy as np
from pathlib import Path


def refine_stump_weights(rig, foot_fade_start=.085, foot_fade_end=.34):
    """Assign soft Body/Foot weights and refresh the existing evaluated proxy.

    The original head and chest weights are preserved by their original formula.
    At Z<=.075 each leg's sole is entirely Foot. Above that, a soft X/Y mask
    leaves the central crotch and deep front/back belly on Body. The Foot fade
    reaches zero at .34 by default. Thigh/shin rotation does not skin the Coat;
    those bones still solve and animate the ankle targets as before.
    """
    root = Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
    helpers = {}
    helper_path = root/'work/refine-locomotion-weights.py'
    exec(compile(helper_path.read_text(), str(helper_path), 'exec'), helpers)
    group_names = helpers['_LOCOMOTION_GROUPS']
    smooth = helpers['_locomotion_smooth']
    coordinates = helpers['_locomotion_coords']
    group_map = helpers['_locomotion_group_map']
    assert_surface = helpers['_locomotion_assert_same_surface']
    extract_weights = helpers['_locomotion_extract_weights']
    replace_weights = helpers['_locomotion_replace_weights']

    assert .075 <= foot_fade_start < foot_fade_end <= .46
    assert rig is not None and rig.type == 'ARMATURE'
    coat = bpy.data.objects['Coat']
    proxy = bpy.data.objects['Coat_FurBindingSurface']
    assert coat.type == proxy.type == 'MESH'
    assert len(coat.data.vertices) == 84257, 'Unexpected Coat topology.'
    mapping = group_map(coat)
    assert mapping == group_map(proxy), 'Coat/proxy group name/index correspondence changed.'
    assert all(coat.vertex_groups.get(name) for name in group_names)
    assert all(rig.data.bones.get(name) and rig.data.bones[name].use_deform for name in group_names)
    assert np.allclose(np.array(coat.matrix_world), np.array(proxy.matrix_world), atol=1e-8, rtol=0)
    assert proxy.data.uv_layers.get('RigBindingUV'), 'Existing binding UV is required.'
    # Retain either existing skinning setting: Body/Foot is primarily a blend
    # of translations, and this helper should not make an unrelated DQS choice.
    skinning = []
    for ob in (coat, proxy):
        modifiers = [mod for mod in ob.modifiers if mod.type == 'ARMATURE']
        assert len(modifiers) == 1 and modifiers[0].object == rig
        skinning.append(bool(modifiers[0].use_deform_preserve_volume))
    assert skinning[0] == skinning[1], 'Source and binding proxy must use the same skinning method.'

    pose_position = rig.data.pose_position
    try:
        rig.data.pose_position = 'REST'
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = coat.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=depsgraph)
        try:
            before_error = assert_surface(mesh, proxy.data)
        finally:
            evaluated.to_mesh_clear()

        p = coordinates(coat.data)
        x, y, z = p[:, 0], p[:, 1], p[:, 2]
        head = smooth(1.02, 1.23, z)
        chest = (1-head)*smooth(.62, 1.00, z)
        central = 1-head-chest
        height_fade = 1-smooth(foot_fade_start, foot_fade_end, z)
        # Separate the two actual stumps from the central belly. Low soles
        # override this mask so their entire cross sections remain rigidly flat.
        x_core = smooth(.025, .115, np.abs(x))
        leg_center_y = -.035*(1-smooth(.075, .30, z))
        y_inner = .20-.09*smooth(.10, .30, z)
        y_core = 1-smooth(y_inner, y_inner+.080, np.abs(y-leg_center_y))
        core_transition = smooth(.075, .145, z)
        core = (1-core_transition)+core_transition*x_core*y_core
        foot_influence = np.clip(height_fade*core, 0.0, 1.0)
        sole = z <= .075
        assert np.all(foot_influence[sole] == 1.0), 'Every sole vertex must be entirely Foot.'
        weights = {name: np.zeros(len(p), np.float32) for name in group_names}
        weights['Head'] = head
        weights['Chest'] = chest
        weights['Body'] = central*(1-foot_influence)
        for side, negative in (('L', True), ('R', False)):
            side_mask = (x < 0) if negative else (x >= 0)
            weights['Foot.'+side] = central*foot_influence*side_mask
        total = np.sum(np.stack([weights[name] for name in group_names]), axis=0)
        assert np.max(np.abs(total-1.0)) < 1e-5
        replace_weights(coat, weights)

        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = coat.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=depsgraph)
        try:
            after_error = assert_surface(mesh, proxy.data)
            assert mapping == group_map(coat) == group_map(proxy)
            interpolated = extract_weights(mesh, mapping)
        finally:
            evaluated.to_mesh_clear()
        proxy_total = np.sum(np.stack([interpolated[name] for name in group_names]), axis=0)
        assert np.max(np.abs(proxy_total-1.0)) <= .00031
        replace_weights(proxy, interpolated)
        bpy.context.view_layer.update()
        return {
            'objects': [coat.name, proxy.name],
            'updated_deform_groups': list(group_names),
            'source_vertices': len(coat.data.vertices),
            'proxy_vertices': len(proxy.data.vertices),
            'method': 'Soft-stump Body/Foot blend; thigh and shin skin weights zero',
            'foot_height_fade_z': [float(foot_fade_start), float(foot_fade_end)],
            'full_foot_below_z': .075,
            'xy_mask_transition_z': [.075, .145],
            'rest_coordinate_error_before': before_error,
            'rest_coordinate_error_after': after_error,
            'preserve_volume_unchanged': skinning[0],
            'proxy_weight_sum_error_before_bucketing': float(np.max(np.abs(proxy_total-1.0))),
            'preserved': 'Geometry, materials, other groups, UVs, hair roots, bones and animation',
        }
    finally:
        rig.data.pose_position = pose_position
        bpy.context.view_layer.update()
