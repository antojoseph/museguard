"""Pure math helpers for the mascot's baked Blender locomotion.

Import this file inside Blender.  It does not import bpy, access a scene, or run
an animation.  All vectors/matrices are in one common armature coordinate space
(normally the rig's identity world space).  Units are metres and seconds.
"""

from dataclasses import dataclass
import math
from mathutils import Matrix, Vector


def smoothstep(value):
    """Cubic ease with zero endpoint velocity, clamped to [0, 1]."""
    value = max(0.0, min(1.0, float(value)))
    return value * value * (3.0 - 2.0 * value)


def two_bone_ik(hip, ankle, upper_length, lower_length, pole, epsilon=1e-6):
    """Return ``(knee, reach_error_metres)`` for a fixed-length two-bone leg.

    ``pole`` is a direction, not a point: use root-yaw @ (0, -1, 0) to make
    knees bend toward the mascot's front.  The returned knee uses a clamped
    reachable distance; positive error means the ankle target is unreachable.
    The caller should reject errors above about .0005 m rather than silently
    accepting foot sliding.  The actual reachable ankle is hip + direction*d.
    """
    hip, ankle, pole = Vector(hip), Vector(ankle), Vector(pole)
    upper_length, lower_length = float(upper_length), float(lower_length)
    if min(upper_length, lower_length) <= epsilon:
        raise ValueError('Both leg lengths must exceed epsilon.')
    delta = ankle - hip
    distance = delta.length
    direction = delta / distance if distance > epsilon else Vector((0, 0, -1))
    minimum = abs(upper_length - lower_length) + epsilon
    maximum = upper_length + lower_length - epsilon
    reach = max(minimum, min(maximum, distance))
    reach_error = abs(distance - reach)
    along = (upper_length ** 2 - lower_length ** 2 + reach ** 2) / (2 * reach)
    height = math.sqrt(max(0.0, upper_length ** 2 - along ** 2))
    bend = pole - direction * pole.dot(direction)
    if bend.length < epsilon:
        fallback = min((Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))),
                       key=lambda axis: abs(axis.dot(direction)))
        bend = fallback - direction * fallback.dot(direction)
    bend.normalize()
    return hip + direction * along + bend * height, reach_error


def bone_target_matrix(rest_bone_matrix, head, target_vector):
    """Return a pose-bone matrix that aims its +Y axis along target_vector.

    Pass the bone's armature-space ``bone.matrix_local``, the desired posed
    head, and ``desired_tail - desired_head``.  Length is not changed.  The
    minimal rotation preserves the rest roll as much as possible.  Assign in
    parent-first order, updating Blender's dependency graph between parents
    and children, then bake both location and rotation for every leg bone.
    """
    direction = Vector(target_vector)
    if direction.length < 1e-10:
        raise ValueError('A target bone direction cannot have zero length.')
    rest_rotation = rest_bone_matrix.to_quaternion().to_matrix()
    rest_direction = rest_rotation @ Vector((0, 1, 0))
    swing = rest_direction.rotation_difference(direction.normalized()).to_matrix()
    result = (swing @ rest_rotation).to_4x4()
    result.translation = Vector(head)
    return result


def swing_interpolate(start, end, progress, lift=.012, clearance=False):
    """Interpolate a continuous swing, including zero-velocity endpoints.

    Flat walking uses a smooth horizontal transfer plus a sine-squared lift.
    ``clearance=True`` raises the foot first, moves it across the riser, and
    lowers it last.  Its apex is max(start.z, end.z) + lift.
    """
    start, end = Vector(start), Vector(end)
    progress = max(0.0, min(1.0, float(progress)))
    if clearance:
        target = start.lerp(end, smoothstep((progress - .25) / .50))
        apex = max(start.z, end.z) + float(lift)
        if progress <= .5:
            target.z = start.z + (apex - start.z) * smoothstep(progress / .25)
        else:
            target.z = apex + (end.z - apex) * smoothstep((progress - .75) / .25)
        return target
    target = start.lerp(end, smoothstep(progress))
    target.z += float(lift) * math.sin(math.pi * progress) ** 2
    return target


def gait_ankle_target(time, root_path, velocity, foot_offset, phase=0.0,
                      cycle=1.1, duty=.62, lift=.012):
    """Return a constant-speed cyclic gait's ankle target.

    ``root_path(t)`` is the horizontal ground/root path, excluding pelvis bob
    and crouch.  It must also work before t=0 for this infinite-cycle helper.
    ``foot_offset`` is the rest ankle offset, rotated by the desired body yaw;
    native offsets are approximately (+/-.25, -.035, .065).  ``velocity`` is
    the world/armature-space horizontal velocity.  Use phases 0 and .5.

    The ankle is exactly stationary for the stance portion.  This helper has
    no start/stop transition: use ``plan_footsteps`` for a finite action.
    """
    if cycle <= 0 or not .5 < duty < 1:
        raise ValueError('Use cycle > 0 and .5 < duty < 1 for overlapping stance.')
    velocity, foot_offset = Vector(velocity), Vector(foot_offset)
    phase_time = float(time) / cycle + float(phase)
    number = math.floor(phase_time)
    fraction = phase_time - number
    contact_time = (number - float(phase)) * cycle
    lead = velocity * (.5 * duty * cycle)
    start = Vector(root_path(contact_time)) + foot_offset + lead
    if fraction <= duty:
        return start
    end = Vector(root_path(contact_time + cycle)) + foot_offset + lead
    return swing_interpolate(start, end, (fraction - duty) / (1 - duty), lift)


@dataclass
class Footstep:
    side: str
    start: float
    end: float
    start_ankle: Vector
    end_ankle: Vector
    lift: float = .012
    clearance: bool = False


@dataclass
class FootstepPlan:
    initial: dict
    steps: tuple
    start_time: float
    travel_end: float
    end_time: float

    def sample(self, side, time):
        """Return ``(ankle_Vector, is_stance_bool)``; fixed before/after plan."""
        ankle = self.initial[side].copy()
        for step in self.steps:
            if step.side != side:
                continue
            if time < step.start:
                break
            if time < step.end:
                progress = (time - step.start) / (step.end - step.start)
                return swing_interpolate(step.start_ankle, step.end_ankle,
                                         progress, step.lift, step.clearance), False
            ankle = step.end_ankle.copy()
        return ankle, True

    def ankle(self, side, time):
        return self.sample(side, time)[0]


def plan_footsteps(root_path, travel_duration, foot_offsets, cycle=1.1,
                   duty=.62, lift=.012, first_side='R', start_time=0.0,
                   ground_height=None, stair_clearance=True):
    """Plan finite alternating foot contacts, with no start/end teleport.

    root_path receives *local* time in [0, travel_duration] and excludes
    pelvis crouch/bob.  Returned step times include start_time.  foot_offsets
    maps L/R to rotated rest-ankle offsets or callables offset(local_time).
    Optional ground_height(x, y, local_time) returns ground z; ankle height is
    then ground + offset.z instead of root_path.z + offset.z.

    The first swing begins at start_time from the exact initial standing
    foot.  Landing locations sample root_path half a stance beyond landing.
    Final closing swings place both feet at root_path(travel_duration) plus
    their rest offsets.  The body must remain at the path endpoint until
    plan.end_time, which can extend up to about one cycle beyond travel_end.
    Between swings every contact stays fixed, even during turns/stops.

    At .07-.10 m/s, cycle 1.1, lift .012, and Body crouch .006, this gives
    conservative plush steps.  Reachability must still be checked per frame.
    """
    if travel_duration < 0 or cycle <= 0 or not .5 < duty < 1:
        raise ValueError('Nonnegative duration, positive cycle, and .5 < duty < 1 required.')
    if set(foot_offsets) != {'L', 'R'} or first_side not in ('L', 'R'):
        raise ValueError('Provide L/R foot offsets and a first_side of L or R.')
    start_time = float(start_time)
    duration = float(travel_duration)
    swing_duration = cycle * (1 - duty)
    half_cycle = .5 * cycle
    lead_time = .5 * duty * cycle

    def contact(side, local_time):
        local_time = max(0.0, min(duration, local_time))
        offset_source = foot_offsets[side]
        offset = Vector(offset_source(local_time) if callable(offset_source) else offset_source)
        point = Vector(root_path(local_time)) + offset
        if ground_height is not None:
            point.z = float(ground_height(point.x, point.y, local_time)) + offset.z
        return point

    initial = {side: contact(side, 0) for side in ('L', 'R')}
    current = {side: point.copy() for side, point in initial.items()}
    completed = {'L': False, 'R': False}
    steps = []
    other_side = 'L' if first_side == 'R' else 'R'
    end_time = start_time + duration
    # One extra cycle lets both feet perform their final closing swing.
    limit = int(math.ceil((duration + 2 * cycle) / half_cycle)) + 4
    for index in range(limit):
        side = first_side if index % 2 == 0 else other_side
        local_start = index * half_cycle
        local_end = local_start + swing_duration
        preview = min(duration, local_end + lead_time)
        target = contact(side, preview)
        final_contact = preview >= duration - 1e-9
        if (target - current[side]).length > 1e-8:
            rise = abs(target.z - current[side].z) > 1e-6
            steps.append(Footstep(side, start_time + local_start,
                                  start_time + local_end, current[side].copy(),
                                  target.copy(), float(lift), bool(stair_clearance and rise)))
            current[side] = target.copy()
            end_time = max(end_time, start_time + local_end)
        completed[side] = final_contact
        if all(completed.values()):
            break
    else:
        raise RuntimeError('Footstep planning did not settle at the final contacts.')
    return FootstepPlan(initial, tuple(steps), start_time,
                        start_time + duration, end_time)


def pelvis_height_limit(hip_xy, ankle_targets, upper_length, lower_length,
                        margin=.001):
    """Maximum common hip z that leaves every ankle within leg reach.

    hip_xy may be a single XY pair or a side -> XY mapping.  This is a ceiling,
    not a full pelvis controller: smoothly lower the desired pelvis below it.
    A ValueError signals an impossible horizontal step and must be resolved
    by shortening the stride rather than sliding a planted foot.
    """
    reach = float(upper_length) + float(lower_length) - float(margin)
    result = math.inf
    items = ankle_targets.items() if hasattr(ankle_targets, 'items') else enumerate(ankle_targets)
    for side, ankle in items:
        xy = hip_xy[side] if hasattr(hip_xy, 'keys') else hip_xy
        dx, dy = float(ankle[0]) - xy[0], float(ankle[1]) - xy[1]
        horizontal_sq = dx * dx + dy * dy
        if horizontal_sq >= reach * reach:
            raise ValueError('An ankle target is beyond horizontal leg reach.')
        result = min(result, float(ankle[2]) + math.sqrt(reach * reach - horizontal_sq))
    return result
