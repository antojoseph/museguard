#!/usr/bin/env python3
"""Derive a weighted, smooth-normal runtime mesh from the credited original STL.
Run with: uv run --with numpy --with trimesh --with scipy --with shapely --with mapbox-earcut --with triangle --with scikit-image --with fast-simplification python scripts/prepare-muse-mesh.py
Original source meshes are never modified. Runtime uses only the committed .musemesh.
"""
from pathlib import Path
import hashlib, json, struct
import numpy as np
import trimesh
from scipy.spatial import cKDTree
from scipy.ndimage import gaussian_filter
from scipy.interpolate import CubicSpline
from skimage.measure import marching_cubes
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Assets/Source/MuseJolly/Meta Muse - Jolly - Whole.stl'
DEST = ROOT / 'Unreal/MuseGuard/Content/Muse/Jolly.musemesh'
original = trimesh.load(SOURCE, process=True)
# The printable STL fuses the arms along the flanks. Separate closed surfaces
# at the inner arm seam before rigging, otherwise a raised arm stretches the
# entire torso into a membrane. Retain the original outer arm/hand surfaces.
body = original.slice_plane([41,0,0], [-1,0,0], cap=True).slice_plane([-41,0,0], [1,0,0], cap=True)
left = original.slice_plane([-41,0,0], [-1,0,0], cap=True)
right = original.slice_plane([41,0,0], [1,0,0], cap=True)
parts = [body, left, right]
assert all(p.is_watertight for p in parts)
# Rebuild cap interiors with well-shaped small triangles while keeping every
# cut boundary vertex. This avoids long fan triangles creasing under animation.
for i, part in enumerate(parts):
    replacements = []
    keep = np.ones(len(part.faces),dtype=bool)
    for side in [-1,1]:
        cap_faces = np.isclose(part.vertices[part.faces][:,:,0],side*41).all(axis=1)
        if not cap_faces.any(): continue
        keep &= ~cap_faces
        cap = part.submesh([np.flatnonzero(cap_faces)],append=True)
        edges = cap.edges_sorted
        boundary_edges = edges[trimesh.grouping.group_rows(edges,require_count=1)]
        boundary = cap.vertices[np.unique(boundary_edges),1:]
        for polygon in trimesh.path.polygons.edges_to_polygons(boundary_edges,cap.vertices[:,1:]):
            yz, ff = trimesh.creation.triangulate_polygon(polygon,engine='triangle',triangle_args='pq25a2Y')
            distances = cKDTree(boundary).query(yz)[0]
            direction = side if i==0 else -side
            xx = side*41 + direction*np.minimum(2.2 if i==0 else 4.,distances*.6)
            vv = np.column_stack([xx,yz])
            if direction<0: ff=ff[:,[0,2,1]]
            replacements.append(trimesh.Trimesh(vv,ff,process=False))
    base = trimesh.Trimesh(part.vertices,part.faces[keep],process=False)
    rebuilt = trimesh.util.concatenate([base,*replacements])
    rebuilt.merge_vertices()
    assert rebuilt.is_watertight, 'Joint repair must leave closed surfaces'
    parts[i] = rebuilt
# Relax print-surface noise while pinning the original facial landmarks,
# then use Loop subdivision to
# round both the silhouette and the repaired shoulders.
for i, part in enumerate(parts):
    px,py,pz = part.vertices.T
    features = (py < -25) & ((((np.abs(px)-12.5)/4.2)**2+((pz-116.9)/4.2)**2<1) | ((np.abs(px)<5)&(np.abs(pz-112)<3)))
    lap = trimesh.smoothing.laplacian_calculation(part,pinned_vertices=np.flatnonzero(features))
    trimesh.smoothing.filter_taubin(part,lamb=.5,nu=.53,iterations=48,laplacian_operator=lap)
    vv,ff = trimesh.remesh.subdivide_loop(part.vertices,part.faces,iterations=1)
    parts[i] = trimesh.Trimesh(vv,ff,process=False)
    assert parts[i].is_watertight
# Uniform volumetric resampling removes the STL's irregular print tessellation.
# Facial landmarks below are fitted back onto the finished surface.
reference_floor = parts[0].bounds[0,2]
reference_top = parts[0].bounds[1,2]
for i, part in enumerate(parts):
    grid = part.voxelized(pitch=.85).fill()
    field = np.pad(grid.matrix.astype(np.float32),3)
    field = gaussian_filter(field,sigma=3.0 if i==0 else 1.8)
    vv,ff,_,_ = marching_cubes(field,level=.5,spacing=(.85,.85,.85))
    vv += grid.transform[:3,3] - 3*.85
    clean = trimesh.Trimesh(vv,ff,process=True)
    trimesh.repair.fix_normals(clean)
    trimesh.smoothing.filter_taubin(clean,lamb=.5,nu=.53,iterations=20)
    # Keep one manageable, evenly distributed animation surface.
    clean = clean.simplify_quadric_decimation(face_count=36000 if i==0 else 6500)
    vv,ff = trimesh.remesh.subdivide_loop(clean.vertices,clean.faces,iterations=1)
    parts[i] = trimesh.Trimesh(vv,ff,process=True)
    assert parts[i].is_watertight
# Preserve the fitted height and floor of the imported character.
low,high = parts[0].bounds[:,2]
for part in parts:
    part.vertices[:,2] = reference_floor+(part.vertices[:,2]-low)*(reference_top-reference_floor)/(high-low)
floor = reference_floor
for part in parts: part.vertices[:,2] -= floor
# One continuous, curved plush limb: broad through the forearm, tapering into
# a rounded end without a narrow wrist or a separate bulb-shaped hand.
def plush_arm(side):
    pitch=.6
    lower=np.array([24.,-27.,18.])
    upper=np.array([72.,24.,96.])
    grid=np.stack(np.meshgrid(*[np.arange(a,b+pitch,pitch) for a,b in zip(lower,upper)],indexing='ij'),axis=-1)
    def ellipsoid(center,radii):
        return (np.sqrt(np.sum(((grid-np.array(center))/np.array(radii))**2,axis=-1))-1)*min(radii)
    def union(a,b,k=2.5):
        h=np.clip(.5+.5*(b-a)/k,0,1)
        return b*(1-h)+a*h-k*h*(1-h)
    z=grid[...,2]
    height=(z-59.)/34.
    shoulder=np.clip((z-38.)/55.,0,1)
    shoulder=shoulder*shoulder*(3-2*shoulder)
    center_x=49.-11.*shoulder
    center_y=-7.+7.*shoulder
    # A gently bowed ellipsoid makes the shoulder, forearm and soft hand one
    # silhouette. The wider lower forearm has no pinched mitten cuff.
    # Rounded end caps keep the fingertips soft rather than the pointed tips
    # produced by stretching a sphere into a long ellipsoid.
    cap=np.maximum(np.abs(height)-.56,0)/.44
    fullness=1-.10*np.minimum(height*height,1)
    sleeve=(np.sqrt(((grid[...,0]-center_x)/(11.8*fullness))**2+
                    ((grid[...,1]-center_y)/(12.*fullness))**2+cap**2)-1)*11.8
    thumb=ellipsoid([41.5,-6,44],[4,7,7])
    field=union(sleeve,thumb,3)
    vv,ff,_,_=marching_cubes(field,level=0,spacing=(pitch,)*3)
    vv+=lower;vv[:,0]*=side
    mesh=trimesh.Trimesh(vv,ff,process=True);trimesh.repair.fix_normals(mesh)
    trimesh.smoothing.filter_taubin(mesh,lamb=.5,nu=.53,iterations=10)
    mesh=mesh.simplify_quadric_decimation(face_count=6500)
    vv,ff=trimesh.remesh.subdivide_loop(mesh.vertices,mesh.faces,iterations=1)
    mesh=trimesh.Trimesh(vv,ff,process=True)
    assert mesh.is_watertight and mesh.volume>0
    return mesh
parts[1],parts[2]=plush_arm(-1),plush_arm(1)
# The printable torso has broad flat panels. Fair those sections into an
# elliptical plush volume without changing the head outline or foot placement.
def ease(a,b,v):
    t=np.clip((v-a)/(b-a),0,1);return t*t*(3-2*t)
pv=parts[0].vertices.copy()
px,py,pz=pv.T
profile=[0,22,35,55,75,95,110,128,140,148,151]
rx=CubicSpline(profile,[24,33,40,44,44,39,37,35,29,16,2],bc_type='natural')(pz)
ry=CubicSpline(profile,[25,34,40,43,43,41,40,36,29,16,2],bc_type='natural')(pz)
r=np.sqrt((px/rx)**2+(py/ry)**2)
blend=ease(20,35,pz)*(1-ease(138,150,pz))
scale=1+blend*(1/np.maximum(r,.2)-1)
pv[:,:2]*=scale[:,None]
parts[0].vertices=pv
trimesh.smoothing.filter_taubin(parts[0],lamb=.5,nu=.53,iterations=12)
# A broad plush rump blends into the back and upper thighs as one surface.
# In the prone pose, the old narrow vertical lobes became pointed humps.
# Spread the volume along the torso so the side silhouette reads as a dome.
rear=parts[0].vertices.copy()
sx,sy,sz=rear.T
rear_mask=ease(.20,.72,sy/np.maximum(np.sqrt(sx*sx+sy*sy),1))
height=np.exp(-.5*((sz-48)/22)**2)*ease(18,40,sz)
cheeks=np.exp(-.5*((sx-16)/11)**2)+np.exp(-.5*((sx+16)/11)**2)
seat=height*(12*np.exp(-.5*(sx/26)**2)+6.5*cheeks)
# A rounded central fold separates the two plush cheeks on the same closed
# surface. Preserve their outer height and blend the fold into the upper thighs.
separation=12*np.exp(-.5*(sx/5.5)**2)*np.exp(-.5*((sz-43)/15)**2)
rear[:,1]+=rear_mask*(seat-separation*ease(18,40,sz))
parts[0].vertices=rear
# Fill the deep print-derived facial recess into a gently convex face panel.
# The old bowl was disguised from the front but formed a dark crater when the
# head turned onto the pillow. Keep a shallow soft rim and refit the features.
face=parts[0].vertices.copy()
fx,fy,fz=face.T
radius=(fx/28.)**2+((fz-116.)/20.)**2
blend=(1-ease(.60,1.20,radius))*(1-ease(-18,-8,fy))
front=-33.5+1.5*np.minimum(radius,1.2)
face[:,1]-=np.maximum(fy-front,0)*blend
parts[0].vertices=face
# A separate closed plush tail stays round when the body settles. Embed most
# of its root in the upper rump; its own triangles share the body fur material.
tail_radius=6.
tail_z=45./.82
rear_surface=parts[0].vertices[parts[0].vertices[:,1]>0]
distance,near=cKDTree(rear_surface[:,[0,2]]).query([0.,tail_z],k=16)
weight=1/np.maximum(distance,.1)**2
tail_rear_y=float(np.sum(rear_surface[near,1]*weight)/np.sum(weight))
tail_center=np.array([0.,tail_rear_y+2./.82,tail_z])
tail_mesh=trimesh.creation.icosphere(subdivisions=3,radius=tail_radius)
tail_mesh.vertices+=tail_center
assert tail_mesh.is_watertight and tail_mesh.volume>0
parts.append(tail_mesh)
# Smooth button eyes and smile follow the source facial landmarks, positioned
# on the rebuilt face rather than left inside the now-filled print recesses.
front=parts[0].vertices[(parts[0].vertices[:,1]<-20)&(parts[0].vertices[:,2]>100)]
face_tree=cKDTree(front[:,[0,2]])
def face_y(x,z):
    d,i=face_tree.query([x,z],k=8);w=1/np.maximum(d,.1)**2
    return np.sum(front[i,1]*w)/w.sum()
eyes=[]
for side in [-1,1]:
    eye=trimesh.creation.uv_sphere(radius=2.7,count=[24,32])
    eye.vertices += [side*12.5,face_y(side*12.5,116.9-floor)+.4,116.9-floor]
    eyes.append(eye)
points=[];smile_faces=[]
for i,x in enumerate(np.linspace(-3.8,3.8,33)):
    z=111.3+.105*x*x-floor
    center=np.array([x,face_y(x,z)-.35,z])
    tangent=np.array([1.,0,.21*x]);tangent/=np.linalg.norm(tangent)
    a=np.array([0.,-1,0]);b=np.cross(tangent,a)
    for angle in np.linspace(0,2*np.pi,8,endpoint=False):
        points.append(center+.62*(np.cos(angle)*a+np.sin(angle)*b))
    if i:
        for j in range(8):
            a0=(i-1)*8+j;b0=(i-1)*8+(j+1)%8;c0=i*8+j;d0=i*8+(j+1)%8
            smile_faces.extend([[a0,c0,b0],[b0,c0,d0]])
for ring in [0,32]:
    center=len(points);points.append(np.mean(points[ring*8:ring*8+8],axis=0))
    for j in range(8): smile_faces.append([center,ring*8+j,ring*8+(j+1)%8])
smile=trimesh.Trimesh(points,smile_faces,process=True);trimesh.repair.fix_normals(smile)
assert smile.is_watertight and smile.volume>0
features=[trimesh.util.concatenate(eyes),smile]
body,left,right = parts[:3]
labels = np.concatenate([np.zeros(sum(len(p.faces) for p in parts),dtype=int),np.ones(len(features[0].faces),dtype=int),np.full(len(features[1].faces),2,dtype=int)])
m = trimesh.util.concatenate([*parts,*features])
v = np.asarray(m.vertices)
x, y, z = v.T
def smooth(lo, hi, value):
    t = np.clip((value - lo) / (hi - lo), 0, 1)
    return t*t*(3-2*t)
head = smooth(80, 114, z)
# Keep the pelvis on the torso and blend the upper legs gradually. A hard
# left/right split makes adjacent crotch triangles fold inside-out in a stride.
feet = 1 - smooth(12, 31, z)
# The rear pelvis belongs to the body, not the bending thigh. Height-only
# weights gave this deep rear volume a long hip lever arm and made it hang
# below the butt like a flap when a climbing foot lifted. Keep the low paws
# and front thighs articulated while anchoring the rounded rear shell.
feet *= 1 - smooth(8, 18, z)*smooth(6, 20, y)
leg_side = smooth(-8, 8, x)
# Twelve weights: torso, head, shoulders, hips, wrists, knees and ankles. The shoulder
# ends blend back into the torso; the separated lower arm keeps its volume.
w = np.zeros((len(v), 12))
arm = np.zeros((len(v), 2))
start = len(body.vertices)
arm[start:start+len(left.vertices),0] = 1-smooth(68,91,z[start:start+len(left.vertices)])
start += len(left.vertices)
arm[start:start+len(right.vertices),1] = 1-smooth(68,91,z[start:start+len(right.vertices)])
w[:, 2:4] = arm
remaining = 1 - arm.sum(axis=1)
w[:, 1] = head * remaining
remaining *= 1-head
w[:, 4] = feet * remaining * (1-leg_side)
w[:, 5] = feet * remaining * leg_side
w[:, 0] = remaining * (1-feet)
for side in range(2):
    leg = w[:,4+side].copy()
    knee = 1-smooth(10,21,z)
    ankle = 1-smooth(3,9,z)
    w[:,4+side] = leg*(1-knee)
    w[:,8+side] = leg*knee*(1-ankle)
    w[:,10+side] = leg*knee*ankle
    wrist = w[:,2+side] * (1-smooth(38,64,z))
    w[:,6+side] = wrist
    w[:,2+side] -= wrist
# The tail follows the torso in the ordinary rig. Runtime identifies this
# closed component separately for the volume-preserving sleep target.
tail_start=sum(len(p.vertices) for p in parts[:3])
tail_end=tail_start+len(tail_mesh.vertices)
w[tail_start:tail_end]=0
w[tail_start:tail_end,0]=1
assert np.isfinite(w).all() and np.allclose(w.sum(axis=1), 1, atol=1e-6)
# STL faces -Y; Unreal camera looks down -X. Rotate coordinates, then reverse STL winding for Unreal below.
transform = np.array([[0,-1,0],[1,0,0],[0,0,1.]])
verts = v @ transform.T * .82
normals = m.vertex_normals @ transform.T
colors = [(0.84,0.79,0.66), (.008,.011,.018), (.018,.013,.014)]
with DEST.open('wb') as f:
    f.write(struct.pack('<III', 0x4D55534B, 3, 3))
    for section in range(3):
        faces = m.faces[labels == section]
        used, inverse = np.unique(faces, return_inverse=True)
        inverse = inverse.reshape(-1, 3)[:, [0, 2, 1]].ravel()
        f.write(struct.pack('<II3f',len(used), len(inverse), *colors[section]))
        packed = np.column_stack([verts[used], normals[used], w[used]]).astype('<f4')
        f.write(packed.tobytes())
        f.write(inverse.astype('<u4').tobytes())
        print(f'section {section}: {len(used)} vertices, {len(faces)} triangles')
metadata = dict(source=str(SOURCE.relative_to(ROOT)), source_sha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    creator='MadDog2125', source_url='https://makerworld.com/en/models/3441016-meta-muse-jolly',
    license='CC BY-NC-SA 4.0', license_url='https://creativecommons.org/licenses/by-nc-sa/4.0/',
    modifications='Separated fused underarms for articulation; rebuilt both arms as continuous curved plush limbs with broad forearms, rounded ends and a subtle fused thumb; broad wrist blending removes the separate mitten cuff. Uniform volumetric surface reconstruction, Taubin relaxation and Loop subdivision; shallow convex face panel replacing the deep printable recess, with smooth button eyes and smile refitted to facial landmarks; elliptical torso fairing with two broad rounded plush cheeks with a soft central fold, blending continuously into the torso and upper thighs, plus a separate small round torso-weighted plush tail. Broader neck skinning. Smooth normals, facial material regions, twelve-bone deformation rig with rear pelvis anchored to the torso and articulated front thighs, hips, knees and paws, 0.82 scale, coordinate rotation and Unreal winding.',
    source_triangles=len(original.faces), vertices=len(v), triangles=len(m.faces), closed_parts=7, articulated_body_parts=3, voxel_pitch=.85, volume_smoothing_sigma=[3.0,1.8,1.8], smoothing_iterations=48, subdivision_levels=1, bones=['torso','head','left_shoulder','right_shoulder','left_hip','right_hip','left_wrist','right_wrist','left_knee','right_knee','left_ankle','right_ankle'],
    pivots=[[0,0,0],[0,0,78],[0,-31.16,65.6],[0,31.16,65.6],[0,-16.4,22],[0,16.4,22],[4.92,-39.36,36.9],[4.92,39.36,36.9],[0,-16.4,11],[0,16.4,11],[0,-16.4,3],[0,16.4,3]])
metadata['tail']=dict(center=(tail_center@transform.T*.82).tolist(),radius=tail_radius*.82,
    vertices=len(tail_mesh.vertices),triangles=len(tail_mesh.faces),torso_weight=1.)
DEST.with_suffix('.json').write_text(json.dumps(metadata, indent=2)+'\n')
print(DEST, DEST.stat().st_size)
