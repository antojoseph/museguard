"""Definitions only: refine the existing mascot's leg skinning in place.

Call refine_leg_weights(rig) from Blender after saving a checkpoint. This helper
does not connect to Blender, change geometry or UVs, rebuild hair attachments,
add modifiers, create groups, or save a file. It restores the rig's pose/rest
display setting even if validation fails. The hidden fur-binding proxy must
already be the rest-evaluated Coat mesh with matching vertex-group indices.
"""

import bpy
import numpy as np


_LOCOMOTION_GROUPS = (
    'Body', 'Chest', 'Head',
    'Leg.L', 'Shin.L', 'Foot.L',
    'Leg.R', 'Shin.R', 'Foot.R',
)


def _locomotion_smooth(a, b, x):
    t = np.clip((x-a)/(b-a), 0.0, 1.0)
    return t*t*(3.0-2.0*t)


def _locomotion_coords(mesh):
    coordinates = np.empty(len(mesh.vertices)*3, np.float32)
    mesh.vertices.foreach_get('co', coordinates)
    return coordinates.reshape(-1, 3)


def _locomotion_group_map(ob):
    return tuple((group.index, group.name) for group in ob.vertex_groups)


def _locomotion_topology(mesh):
    """Fingerprint connectivity by vertex index, without touching any layer."""
    edges = np.empty(len(mesh.edges)*2, np.int32)
    loops = np.empty(len(mesh.loops), np.int32)
    starts = np.empty(len(mesh.polygons), np.int32)
    sizes = np.empty(len(mesh.polygons), np.int32)
    mesh.edges.foreach_get('vertices', edges)
    mesh.loops.foreach_get('vertex_index', loops)
    mesh.polygons.foreach_get('loop_start', starts)
    mesh.polygons.foreach_get('loop_total', sizes)
    return (len(mesh.vertices), edges, loops, starts, sizes)


def _locomotion_assert_same_surface(mesh, proxy_mesh, tolerance=1e-6):
    expected = _locomotion_topology(proxy_mesh)
    actual = _locomotion_topology(mesh)
    assert actual[0] == expected[0], 'Fur proxy vertex count changed; do not rebind implicitly.'
    assert all(np.array_equal(a, b) for a, b in zip(actual[1:], expected[1:])), (
        'Fur proxy connectivity/order does not match the rest-evaluated Coat.'
    )
    delta = _locomotion_coords(mesh).astype(np.float64) - _locomotion_coords(proxy_mesh)
    maximum = float(np.linalg.norm(delta, axis=1).max(initial=0.0))
    assert maximum <= tolerance, (
        'Fur proxy rest coordinates differ from Coat by %.9g m.' % maximum
    )
    return maximum


def _locomotion_extract_weights(mesh, group_map):
    index_to_name = {index: name for index, name in group_map if name in _LOCOMOTION_GROUPS}
    weights = {name: np.zeros(len(mesh.vertices), np.float32) for name in _LOCOMOTION_GROUPS}
    for vertex in mesh.vertices:
        for assignment in vertex.groups:
            name = index_to_name.get(assignment.group)
            if name is not None:
                weights[name][vertex.index] = assignment.weight
    return weights


def _locomotion_replace_weights(ob, weights):
    """Clear obsolete assignments, then use the original rig's 1e-4 buckets."""
    count = len(ob.data.vertices)
    indices = list(range(count))
    for name in _LOCOMOTION_GROUPS:
        values = np.asarray(weights[name], np.float64)
        assert len(values) == count and np.all(np.isfinite(values))
        assert values.min(initial=0.0) >= -1e-6 and values.max(initial=0.0) <= 1.000001
        group = ob.vertex_groups[name]
        # Clearing is essential: REPLACE alone leaves old nonzero upper-hip weights.
        group.remove(indices)
        buckets = np.rint(np.clip(values, 0.0, 1.0)*10000).astype(np.int32)
        positive = np.flatnonzero(buckets > 0)
        if not len(positive):
            continue
        order = positive[np.argsort(buckets[positive], kind='stable')]
        split = np.flatnonzero(np.diff(buckets[order]))+1
        for members in np.split(order, split):
            group.add(members.tolist(), int(buckets[members[0]])/10000.0, 'REPLACE')
    ob.data.update()
    ob.update_tag()


def refine_leg_weights(rig):
    """Keep upper-body skinning, localize hip motion, and update the fur proxy.

    The thigh fades into Body over Z=.27-.46 instead of .32-.62. This removes
    leg rotation from the upper belly, while retaining soft hip blending and
    the existing thigh/shin/foot division. Negative X remains the rig's L side.
    Only the nine listed deformation groups are rewritten on Coat and its
    existing binding proxy. FurDensity, LegFur, UVs and curve data are untouched.
    """
    assert rig is not None and rig.type == 'ARMATURE', 'Expected the existing Mascot Rig.'
    coat = bpy.data.objects['Coat']
    proxy = bpy.data.objects['Coat_FurBindingSurface']
    assert coat.type == proxy.type == 'MESH'
    assert len(coat.data.vertices) == 84257, 'Unexpected Coat topology; inspect before editing.'
    mapping = _locomotion_group_map(coat)
    assert mapping == _locomotion_group_map(proxy), 'Coat/proxy group name/index correspondence changed.'
    assert all(coat.vertex_groups.get(name) for name in _LOCOMOTION_GROUPS)
    assert all(rig.data.bones.get(name) and rig.data.bones[name].use_deform for name in _LOCOMOTION_GROUPS)
    assert np.allclose(np.array(coat.matrix_world), np.array(proxy.matrix_world), atol=1e-8, rtol=0)
    for ob in (coat, proxy):
        modifiers = [mod for mod in ob.modifiers if mod.type == 'ARMATURE']
        assert len(modifiers) == 1 and modifiers[0].object == rig
        assert not modifiers[0].use_deform_preserve_volume, 'Keep the existing linear skinning method.'
    assert proxy.data.uv_layers.get('RigBindingUV'), 'The existing hair-binding UV layer is required.'

    pose_position = rig.data.pose_position
    try:
        rig.data.pose_position = 'REST'
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = coat.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=depsgraph)
        try:
            before_error = _locomotion_assert_same_surface(mesh, proxy.data)
        finally:
            evaluated.to_mesh_clear()

        p = _locomotion_coords(coat.data)
        x, z = p[:, 0], p[:, 2]
        head = _locomotion_smooth(1.02, 1.23, z)
        chest = (1-head)*_locomotion_smooth(.62, 1.00, z)
        central = 1-head-chest
        leg = (1-_locomotion_smooth(.27, .46, z))*_locomotion_smooth(.008, .070, np.abs(x))
        leg = np.where(z < .11, 1.0, leg)
        foot = 1-_locomotion_smooth(.045, .13, z)
        thigh = _locomotion_smooth(.15, .30, z)
        weights = {'Head': head, 'Chest': chest, 'Body': central*(1-leg)}
        for side, negative in (('L', True), ('R', False)):
            side_mask = (x < 0) if negative else (x >= 0)
            strength = central*leg*side_mask
            weights['Leg.'+side] = strength*thigh
            weights['Shin.'+side] = strength*(1-thigh)*(1-foot)
            weights['Foot.'+side] = strength*(1-thigh)*foot
        total = np.sum(np.stack([weights[name] for name in _LOCOMOTION_GROUPS]), axis=0)
        assert np.max(np.abs(total-1.0)) < 1e-5, 'New Coat deformation weights must sum to one.'
        _locomotion_replace_weights(coat, weights)

        # Subdivision interpolates the new source weights onto precisely the
        # established proxy's vertex order. Never recreate its mesh or UV islands.
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = coat.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=depsgraph)
        try:
            after_error = _locomotion_assert_same_surface(mesh, proxy.data)
            assert mapping == _locomotion_group_map(coat) == _locomotion_group_map(proxy)
            interpolated = _locomotion_extract_weights(mesh, mapping)
        finally:
            evaluated.to_mesh_clear()
        proxy_total = np.sum(np.stack([interpolated[name] for name in _LOCOMOTION_GROUPS]), axis=0)
        assert np.max(np.abs(proxy_total-1.0)) <= .00031, 'Unexpected interpolated deformation weight total.'
        _locomotion_replace_weights(proxy, interpolated)
        bpy.context.view_layer.update()
        return {
            'objects': [coat.name, proxy.name],
            'updated_deform_groups': list(_LOCOMOTION_GROUPS),
            'leg_fade_z': [.27, .46],
            'old_leg_fade_z': [.32, .62],
            'source_vertices': len(coat.data.vertices),
            'proxy_vertices': len(proxy.data.vertices),
            'rest_coordinate_error_before': before_error,
            'rest_coordinate_error_after': after_error,
            'proxy_weight_sum_error_before_bucketing': float(np.max(np.abs(proxy_total-1.0))),
            'weight_bucket_step': .0001,
            'skinning': 'Existing linear blend skinning retained',
            'preserved': 'Geometry, materials, other groups, UVs and all hair-root data',
        }
    finally:
        rig.data.pose_position = pose_position
        bpy.context.view_layer.update()
