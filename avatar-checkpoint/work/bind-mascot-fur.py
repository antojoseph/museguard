"""Blender 5.2 native hair binding helpers. Import/exec definitions, then call bind_all_fur(rig).

No operators, pose changes, object deletion, or automatic execution. The existing
hair positions/radii and visual meshes are never rewritten. Direct binding is the
default; use a rest-evaluated binding proxy only if the neutral-pose check needs it.
"""
import bpy
import math
import time
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

UV_NAME = 'RigBindingUV'
GROUP_NAME = 'Mascot Fur Surface Deform'
MOD_NAME = 'Follow Mascot Skin'


def make_binding_uv(surface):
    """Separate, nonoverlapping polygon islands, preserving any existing UV layers."""
    me = surface.data
    uv = me.uv_layers.get(UV_NAME) or me.uv_layers.new(name=UV_NAME)
    grid = max(1, math.ceil(math.sqrt(len(me.polygons))))
    coords = np.zeros((len(me.loops), 2), np.float32)
    for poly in me.polygons:
        n = poly.loop_total
        if n == 4:
            local = np.array(((.1, .1), (.9, .1), (.9, .9), (.1, .9)), np.float32)
        elif n == 3:
            local = np.array(((.1, .1), (.9, .1), (.1, .9)), np.float32)
        else:
            theta = np.arange(n, dtype=np.float64) * (2 * math.pi / n)
            local = np.column_stack((.5 + .4*np.cos(theta), .5 + .4*np.sin(theta)))
        cell = np.array((poly.index % grid, poly.index // grid))
        coords[poly.loop_start:poly.loop_start+n] = (local + cell) / grid
    uv.data.foreach_set('uv', coords.ravel())
    surface.add_rest_position_attribute = True
    for mod in surface.modifiers:
        if mod.type == 'SUBSURF':
            mod.uv_smooth = 'NONE'
    me.update()
    return UV_NAME


def make_rest_binding_proxy(surface, rig):
    """Optional hidden evaluated-rest mesh: identical source/evaluated rest topology.

    Call in neutral pose only. Evaluated vertex-group weights are retained by
    new_from_object; source.copy preserves their group-index/name correspondence.
    """
    deps = bpy.context.evaluated_depsgraph_get()
    evaluated = surface.evaluated_get(deps)
    me = bpy.data.meshes.new_from_object(evaluated, preserve_all_data_layers=True, depsgraph=deps)
    proxy = surface.copy()
    proxy.data = me
    proxy.name = surface.name + '_FurBindingSurface'
    bpy.context.scene.collection.objects.link(proxy)
    for mod in list(proxy.modifiers):
        if mod.type != 'ARMATURE':
            proxy.modifiers.remove(mod)
        else:
            mod.object = rig
    if not any(mod.type == 'ARMATURE' for mod in proxy.modifiers):
        mod = proxy.modifiers.new('Binding Skeleton', 'ARMATURE')
        mod.object = rig
    proxy.add_rest_position_attribute = True
    proxy.hide_render = True
    proxy.hide_set(True)
    proxy['Purpose'] = 'Hidden rest-evaluated surface for exact neutral fur attachment'
    return proxy


def surface_sampling_data(surface):
    """Return evaluated triangle BVH and per-triangle positions/UVs in local space."""
    deps = bpy.context.evaluated_depsgraph_get()
    evaluated = surface.evaluated_get(deps)
    me = evaluated.to_mesh(preserve_all_data_layers=True, depsgraph=deps)
    try:
        me.calc_loop_triangles()
        verts = np.empty(len(me.vertices)*3, np.float32)
        me.vertices.foreach_get('co', verts)
        verts = verts.reshape(-1, 3)
        triangles = np.empty(len(me.loop_triangles)*3, np.int32)
        loops = np.empty_like(triangles)
        me.loop_triangles.foreach_get('vertices', triangles)
        me.loop_triangles.foreach_get('loops', loops)
        triangles = triangles.reshape(-1, 3)
        loops = loops.reshape(-1, 3)
        uv = np.empty(len(me.loops)*2, np.float32)
        me.uv_layers[UV_NAME].data.foreach_get('uv', uv)
        uv = uv.reshape(-1, 2)
        # All triangles are explicit, so BVH polygon indices match loop_triangles.
        bvh = BVHTree.FromPolygons(verts.tolist(), triangles.tolist(), all_triangles=True)
        return bvh, verts[triangles].astype(np.float64), uv[loops].astype(np.float64)
    finally:
        evaluated.to_mesh_clear()


def curve_root_positions(curves):
    count = len(curves.curves)
    points = len(curves.points)
    if not count or points % count:
        raise ValueError('Expected the existing uniform 5/7-point mascot strands')
    stride = points // count
    if stride not in (5, 7):
        raise ValueError('Unexpected strand topology; do not guess root indices')
    pos = np.empty(points*3, np.float32)
    curves.position_data.foreach_get('vector', pos)
    return pos.reshape(-1, 3)[::stride].copy()


def fur_surface_group():
    group = bpy.data.node_groups.get(GROUP_NAME)
    if group:
        return group
    group = bpy.data.node_groups.new(GROUP_NAME, 'GeometryNodeTree')
    group.interface.new_socket(name='Geometry', in_out='INPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket(name='Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
    source = group.nodes.new('NodeGroupInput')
    deform = group.nodes.new('GeometryNodeDeformCurvesOnSurface')
    output = group.nodes.new('NodeGroupOutput')
    source.location = (-250, 0)
    output.location = (250, 0)
    group.links.new(source.outputs['Geometry'], deform.inputs['Curves'])
    group.links.new(deform.outputs['Curves'], output.inputs['Geometry'])
    return group


def bind_one_fur(fur, surface, sampling=None, progress_every=100000):
    t0 = time.monotonic()
    bvh, triangles, triangle_uv = sampling or surface_sampling_data(surface)
    roots = curve_root_positions(fur.data)
    transform = np.array(surface.matrix_world.inverted() @ fur.matrix_world, np.float64)
    roots = roots.astype(np.float64) @ transform[:3, :3].T + transform[:3, 3]
    count = len(roots)
    nearest = np.empty((count, 3), np.float64)
    indices = np.empty(count, np.int32)
    max_distance = 0.0
    for i, root in enumerate(roots):
        point, normal, tri_index, distance = bvh.find_nearest(Vector(root))
        if tri_index is None:
            raise RuntimeError('No surface triangle found for ' + fur.name)
        nearest[i] = point
        indices[i] = tri_index
        max_distance = max(max_distance, distance)
        if (i+1) % progress_every == 0:
            print('Binding', fur.name, i+1, '/', count, flush=True)
    tri = triangles[indices]
    e0, e1 = tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0]
    delta = nearest-tri[:, 0]
    d00 = np.einsum('ij,ij->i', e0, e0)
    d01 = np.einsum('ij,ij->i', e0, e1)
    d11 = np.einsum('ij,ij->i', e1, e1)
    d20 = np.einsum('ij,ij->i', delta, e0)
    d21 = np.einsum('ij,ij->i', delta, e1)
    denom = d00*d11-d01*d01
    if np.any(np.abs(denom) < 1e-24):
        raise RuntimeError('Degenerate surface triangles encountered')
    v = (d11*d20-d01*d21)/denom
    w = (d00*d21-d01*d20)/denom
    bary = np.column_stack((1-v-w, v, w))
    # Avoid numerical ambiguity exactly at an island boundary.
    bary = np.maximum(bary, 1e-6)
    bary /= bary.sum(axis=1, keepdims=True)
    coordinates = np.einsum('ij,ijk->ik', bary, triangle_uv[indices]).astype(np.float32)
    attr = fur.data.attributes.get('surface_uv_coordinate')
    if attr and (attr.data_type != 'FLOAT2' or attr.domain != 'CURVE'):
        raise RuntimeError('Unexpected existing surface_uv_coordinate attribute')
    attr = attr or fur.data.attributes.new('surface_uv_coordinate', 'FLOAT2', 'CURVE')
    attr.data.foreach_set('vector', coordinates.ravel())
    fur.data.surface = surface
    fur.data.surface_uv_map = UV_NAME
    mod = fur.modifiers.get(MOD_NAME) or fur.modifiers.new(MOD_NAME, 'NODES')
    mod.node_group = fur_surface_group()
    fur.data.update_tag()
    result = dict(object=fur.name, surface=surface.name, curves=count,
                  max_root_surface_distance=max_distance,
                  seconds=round(time.monotonic()-t0, 2))
    print('Bound fur:', result, flush=True)
    return result


def bind_all_fur(rig, use_coat_proxy=False):
    """Bind all existing fur in neutral pose, return per-object statistics."""
    results = []
    for emitter_name in ('Coat', 'Arm_L', 'Arm_R'):
        emitter = bpy.data.objects[emitter_name]
        source = make_rest_binding_proxy(emitter, rig) if emitter_name == 'Coat' and use_coat_proxy else emitter
        make_binding_uv(source)
        bpy.context.view_layer.update()
        sampling = surface_sampling_data(source)
        if emitter_name == 'Coat':
            names = ('Coat_PlushGroom', 'Coat_WispyPile', 'FaceEdge_PlushGroom',
                     'Legs_PlushGroom', 'Legs_WispyPile')
        else:
            names = (emitter_name+'_PlushGroom', emitter_name+'_WispyPile')
        for name in names:
            fur = bpy.data.objects.get(name)
            if fur:
                results.append(bind_one_fur(fur, source, sampling))
    bpy.context.view_layer.update()
    return results
