#!/usr/bin/env python3
"""Fit Coco Jinjo's CC BY-NC glasses to Muse's animated attachment.
Run: uv run --with trimesh --with numpy --with scipy --with fast-simplification python scripts/prepare-round-glasses.py
The source remains unchanged; runtime geometry uses centimeters.
"""
from pathlib import Path
import hashlib
import json
import numpy as np
import trimesh
ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'Assets/Source/CocoJinjoGlasses/glasses.glb'
scene = trimesh.load(source, force='scene')
parts = []
for node in sorted(scene.graph.nodes_geometry):
    transform, geometry = scene.graph[node]
    mesh = scene.geometry[geometry].copy()
    mesh.apply_transform(transform)
    glass = mesh.visual.material.name == 'Glass'
    # Source +Z faces forward. Muse +X faces forward, Y across, Z up.
    # Compress human temple length to fit the plush head and existing paw grip.
    fit = np.array([[0,0,4.5,0], [7.2,0,0,0], [0,7.2,0,-7.2*1.044], [0,0,0,1]])
    mesh.apply_transform(fit)
    if node.startswith('pCylinder') or node.startswith(('pCube1_', 'pCube5_')):
        mesh.merge_vertices()
        mesh = mesh.simplify_quadric_decimation(face_count=max(240,len(mesh.faces)//8))
    if node in ('polySurface1_Copper_0', 'polySurface4_Copper_0'):
        mesh.vertices += mesh.vertex_normals * .50
    mesh.update_faces(mesh.nondegenerate_faces())
    mesh.remove_unreferenced_vertices()
    vertices, normals, indices = np.asarray(mesh.vertices), np.asarray(mesh.vertex_normals), np.asarray(mesh.faces)
    # A collapsed hinge fan may have cancelling weighted normals; use an
    # incident face normal rather than writing a zero lighting normal.
    normals = normals.copy()
    for i in np.flatnonzero(np.linalg.norm(normals, axis=1) < .5):
        face = np.flatnonzero((indices == i).any(axis=1))[0]
        normals[i] = mesh.face_normals[face]
    assert np.isfinite(vertices).all() and np.isfinite(normals).all()
    assert indices.min() >= 0 and indices.max() < len(vertices)
    assert np.allclose(np.linalg.norm(normals,axis=1),1,atol=.01)
    parts.append(dict(name=node,material='glass' if glass else 'frame',vertices=vertices.round(6).tolist(),
                      normals=normals.round(6).tolist(),indices=indices.flatten().tolist()))
assert len(parts)==13 and sum(p['material']=='glass' for p in parts)==2
vertices=np.concatenate([p['vertices'] for p in parts])
assert np.max(np.abs(vertices[:,1])) < 21 and vertices[:,0].min() > -19
output=ROOT/'Unreal/MuseGuard/Content/Muse/RoundGlasses.json'
output.write_text(json.dumps(dict(version=1,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    source='https://sketchfab.com/3d-models/glasses-45bd43443daa4b65b5511aed74422338',
    license='CC-BY-NC-4.0',parts=parts),separators=(',',':'))+'\n')
print(f'{output}: {sum(len(p["indices"])//3 for p in parts)} triangles')
