"""Run in Blender after bake-locomotion.py. Copies actions; does not save a file.

The combined showcase stays active. This script never changes geometry, weights,
hair attachments, facial drivers or the existing animation action.
"""

import bpy
import json
import math


def _locomotion_clip_curves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    yield bag, curve


def _locomotion_clip_shift_key(key, shift_x, shift_y=0.0):
    co = key.co.copy()
    left = key.handle_left.copy()
    right = key.handle_right.copy()
    key.co = (co.x-shift_x, co.y-shift_y)
    key.handle_left = (left.x-shift_x, left.y-shift_y)
    key.handle_right = (right.x-shift_x, right.y-shift_y)


def create_locomotion_clips():
    scene = bpy.context.scene
    rig = bpy.data.objects['Mascot Rig']
    assert rig.animation_data and rig.animation_data.action, 'Bake the combined action first.'
    combined = rig.animation_data.action
    assert combined.name == 'Showcase - eight directions and stair climb', (
        'Expected the combined locomotion showcase to be active.'
    )
    assert scene.render.fps == 24 and scene.render.fps_base == 1.0
    root_path = 'pose.bones["Root"].location'
    labels = ['Forward', 'Backward', 'Left', 'Right',
              'Forward left', 'Forward right', 'Back left', 'Back right']
    specs = [('Walk - '+label, 1+48*i, 48+48*i, True)
             for i, label in enumerate(labels)]
    specs.append(('Climb - Two steps', 385, 528, False))
    assert not any(bpy.data.actions.get(name) for name, *_ in specs), (
        'A destination clip already exists. Inspect it before replacing animation.'
    )
    source_curves = list(_locomotion_clip_curves(combined))
    assert source_curves and all(len(curve.keyframe_points) == 528
                                 for _, curve in source_curves), (
        'Expected every baked bone and face channel to contain all 528 frames.'
    )
    source_face_channels = {(curve.data_path, curve.array_index)
                            for _, curve in source_curves
                            if curve.data_path.startswith('pose.bones["Head"][')}
    assert len(source_face_channels) == 4, 'Expected the four baked facial float properties.'
    combined.use_fake_user = True
    report = []
    made = []
    try:
        for name, start, end, rebase in specs:
            clip = combined.copy()
            made.append(clip)
            clip.name = name
            clip.use_fake_user = True
            count = end-start+1
            for bag, curve in list(_locomotion_clip_curves(clip)):
                for index in range(len(curve.keyframe_points)-1, -1, -1):
                    key = curve.keyframe_points[index]
                    if key.co.x < start-1e-5 or key.co.x > end+1e-5:
                        curve.keyframe_points.remove(key, fast=True)
                assert len(curve.keyframe_points) == count, (name, curve.data_path, 'Missing baked key')
                for key in curve.keyframe_points:
                    _locomotion_clip_shift_key(key, start-1)
                curve.update()
            root_curves = {curve.array_index: curve
                           for _, curve in _locomotion_clip_curves(clip)
                           if curve.data_path == root_path}
            assert set(root_curves) == {0, 1, 2}, 'Expected all three Root location channels.'
            first = [float(root_curves[i].keyframe_points[0].co.y) for i in range(3)]
            if rebase:
                # Root.location is expressed in the rest bone's local basis.
                # Subtract its first local vector; do not use world XYZ offsets.
                for component, curve in root_curves.items():
                    for key in curve.keyframe_points:
                        _locomotion_clip_shift_key(key, 0.0, first[component])
                    curve.update()
            else:
                assert math.sqrt(sum(v*v for v in first)) < 1e-5, 'The stair climb must already start at zero.'
            clip_curves = list(_locomotion_clip_curves(clip))
            assert len(clip_curves) == len(source_curves), 'A bone or face channel was lost.'
            face_channels = {(curve.data_path, curve.array_index)
                             for _, curve in clip_curves
                             if curve.data_path.startswith('pose.bones["Head"][')}
            assert face_channels == source_face_channels, 'All custom float facial channels must be retained.'
            assert all(abs(curve.keyframe_points[0].co.x-1) < 1e-5 and
                       abs(curve.keyframe_points[-1].co.x-count) < 1e-5
                       for _, curve in clip_curves)
            if rebase:
                assert max(abs(curve.keyframe_points[0].co.y) for curve in root_curves.values()) < 1e-6
            if hasattr(clip, 'use_frame_range'):
                clip.use_frame_range = True
                clip.frame_start = 1
                clip.frame_end = count
            if hasattr(clip, 'use_cyclic'):
                clip.use_cyclic = False
            clip['Source action'] = combined.name
            clip['Source frame start'] = start
            clip['Source frame end'] = end
            clip['FPS'] = 24
            clip['Motion type'] = 'Translated root motion; start rebased to zero' if rebase else 'Translated root motion; stair climb'
            clip['Root offset removed'] = first if rebase else [0.0, 0.0, 0.0]
            end_root = [float(root_curves[i].keyframe_points[-1].co.y) for i in range(3)]
            report.append({
                'name': clip.name,
                'frames': [1, count],
                'frame_count': count,
                'duration_seconds': count/24.0,
                'channels': len(clip_curves),
                'keys': sum(len(curve.keyframe_points) for _, curve in clip_curves),
                'facial_float_channels': len(face_channels),
                'root_start_local': [float(root_curves[i].keyframe_points[0].co.y) for i in range(3)],
                'root_end_local': end_root,
                'root_offset_removed': first if rebase else [0.0, 0.0, 0.0],
                'fake_user': clip.use_fake_user,
            })
        assert rig.animation_data.action == combined, 'The combined showcase must stay active.'
        assert all(len(curve.keyframe_points) == 528 for _, curve in _locomotion_clip_curves(combined))
    except Exception:
        # Only new, unused copies are removed if a validation fails. The combined
        # action and any older actions are never modified or unlinked.
        for clip in made:
            bpy.data.actions.remove(clip)
        raise
    notes = bpy.data.texts.get('LOCOMOTION - individual clips') or bpy.data.texts.new('LOCOMOTION - individual clips')
    notes.clear()
    notes.write(
        'INDIVIDUAL LOCOMOTION CLIPS\n\n'
        'Nine native Blender actions are saved with Fake User enabled.\n'
        'Walk - Forward / Backward / Left / Right / Forward left / Forward right / Back left / Back right:\n'
        '  Each spans frames 1-48 at 24 fps (2 seconds), with 0.20 m of root translation.\n'
        'Climb - Two steps:\n'
        '  Frames 1-144 at 24 fps (6 seconds), moving forward 0.74 m and upward 0.11 m.\n\n'
        'Each walk starts with Root.location=(0,0,0); local Root offsets have been removed.\n'
        'These are translated start/walk/stop actions, not in-place repeating loops.\n'
        'All bone channels and the four float facial-property channels are retained.\n'
        'The 528-frame combined showcase remains active for the staged movie.\n'
        'To inspect one clip, select Mascot Rig and choose its action in the Action Editor.\n'
        'Stage labels and stair visibility belong to the combined timeline, not these character actions.\n'
        'The detailed fur still needs a separate optimized representation for native-app runtime use.\n'
    )
    print(json.dumps({'active_action': combined.name, 'action_count': len(report), 'clips': report}))
    return report


LOCOMOTION_CLIP_REPORT = create_locomotion_clips()
