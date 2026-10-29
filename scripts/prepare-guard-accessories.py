#!/usr/bin/env python3
"""Build fitted, swappable 3D guard accessories. Run with uv --with numpy --with trimesh --with scipy --with networkx."""
from pathlib import Path
import json,math,struct
from scipy.spatial import cKDTree
import numpy as np
import trimesh
ROOT=Path(__file__).resolve().parents[1]
meshes={};parts=[]
NAVY=[.018,.038,.085];BAND=[.009,.016,.032];GOLD=[.83,.48,.105];SILVER=[.85,.89,.94]
def add(name,mesh,color,socket='head',material='satin',position=(0,0,0)):
    mesh.update_faces(mesh.nondegenerate_faces());mesh.remove_unreferenced_vertices();mesh.fix_normals()
    assert np.isfinite(mesh.vertices).all() and np.isfinite(mesh.vertex_normals).all()
    meshes[name]={'vertices':np.round(mesh.vertices,5).tolist(),'normals':np.round(mesh.vertex_normals,6).tolist(),'indices':mesh.faces[:,[0,2,1]].ravel().tolist()}
    parts.append(dict(socket=socket,geometry=name,position=list(position),size=[1,1,1],color=color,material=material))
def loft(rings,n=96):
    # Rings are (center X, Z, radius X, radius Y), in head-socket space.
    v=[];f=[]
    for x,z,rx,ry in rings:
        for j in range(n):
            a=2*math.pi*j/n;v.append([x+rx*math.cos(a),ry*math.sin(a),z])
    for r in range(len(rings)-1):
        for j in range(n):
            a=r*n+j;b=r*n+(j+1)%n;c=a+n;d=b+n
            f.extend([[a,b,d],[a,d,c]])
    for ring in [0,len(rings)-1]:
        center=len(v);v.append([rings[ring][0],0,rings[ring][1]])
        for j in range(n): f.append([center,ring*n+j,ring*n+(j+1)%n])
    return trimesh.Trimesh(v,f,process=True)
def tube(points,radius,n=10):
    pts=np.array(points,float);v=[];f=[]
    for i,p in enumerate(pts):
        t=pts[min(i+1,len(pts)-1)]-pts[max(i-1,0)];t/=np.linalg.norm(t)
        ref=np.array([0.,0.,1.]) if abs(t[2])<.9 else np.array([1.,0.,0.])
        a=np.cross(t,ref);a/=np.linalg.norm(a);b=np.cross(t,a)
        for j in range(n): v.append(p+radius*(a*math.cos(j*2*math.pi/n)+b*math.sin(j*2*math.pi/n)))
    for i in range(len(pts)-1):
        for j in range(n):
            a=i*n+j;b=i*n+(j+1)%n;f.extend([[a,b,b+n],[a,b+n,a+n]])
    for r in [0,len(pts)-1]:
        center=len(v);v.append(pts[r])
        for j in range(n): f.append([center,r*n+j,r*n+(j+1)%n])
    return trimesh.Trimesh(v,f,process=True)
# Fitted at world Z 112–117; head socket is at Z 78. The crown encloses
# the original hood and the close band follows its actual upper-head oval.
add('CapBand',loft([(-4,33.3,24.8,26.7),(-4,34,25.5,27.4),(-4,38.6,25.5,27.4),(-4,39.2,25,27)]),BAND)
add('CapCrown',loft([(-4,38.5,25.3,27.2),(-3.5,40.2,27.8,29.5),(-2,45.5,27,29),(-.8,48.8,23,25.5),(0,50.8,16,18),(0,51.6,7,8),(0,51.7,.4,.5)]),NAVY)
# A swept visor with thickness, rather than another flattened sphere.
v=[];f=[];segments=64;steps=8
for layer in range(2):
    for i in range(segments+1):
        a=-1.16+2.32*i/segments;fade=math.cos(a/1.16*math.pi/2)
        for j in range(steps+1):
            t=j/steps
            v.append([-4+25.5*math.cos(a)+t*13.5*fade,27.4*math.sin(a)+t*2*math.sin(a)*fade,35.7-2.5*t*fade+.55*math.sin(a)**2-layer*.95])
stride=steps+1;surface=(segments+1)*stride
for layer in range(2):
    off=layer*surface
    for i in range(segments):
        for j in range(steps):
            a=off+i*stride+j;f.extend([[a,a+stride,a+stride+1],[a,a+stride+1,a+1]])
boundary=[i*stride for i in range(segments+1)]+[segments*stride+j for j in range(1,steps+1)]+[i*stride+steps for i in range(segments-1,-1,-1)]+[j for j in range(steps-1,0,-1)]
for a,b in zip(boundary,boundary[1:]+boundary[:1]): f.extend([[a,b,b+surface],[a,b+surface,a+surface]])
add('CurvedVisor',trimesh.Trimesh(v,f,process=True),BAND)
add('CapBraid',tube([[-4+25.9*math.cos(a),27.8*math.sin(a),38.1] for a in np.linspace(-1.25,1.25,75)],.43),GOLD,material='metal')
# Small anchor buttons where the braid terminates.
for sign in [-1,1]:
    m=trimesh.creation.icosphere(subdivisions=2,radius=1)
    m.apply_scale([.75,1.3,1.3]);m.apply_translation([4.8,sign*26.3,38.1])
    add(f'BraidButton{sign}',m,GOLD,material='metal')
# Shield silhouette: broad shoulders, straight upper sides, unmistakable point.
shield=np.array([[0,11.5],[-8.3,10],[-10,6.3],[-9.3,-.6],[-6.8,-6.4],[0,-12.5],[6.8,-6.4],[9.3,-.6],[10,6.3],[8.3,10]],float)
def plaque(outline,rings,warp):
    v=[];f=[];n=len(outline)
    for scale,depth in rings:
        for y,z in outline*scale: v.append(warp(depth,y,z))
    for r in range(len(rings)-1):
        for j in range(n):
            a=r*n+j;b=r*n+(j+1)%n;f.extend([[a,b,b+n],[a,b+n,a+n]])
    for r in [0,len(rings)-1]:
        c=len(v);center=outline.mean(axis=0)*rings[r][0];v.append(warp(rings[r][1],*center))
        for j in range(n): f.append([c,r*n+j,r*n+(j+1)%n])
    return trimesh.Trimesh(v,f,process=True)
def star(radius):
    return np.array([[math.sin(i*math.pi/5)*(radius if i%2==0 else radius*.44),math.cos(i*math.pi/5)*(radius if i%2==0 else radius*.44)] for i in range(10)])
def badge(prefix,scale,warp,socket):
    outline=shield*scale
    add(prefix+'GoldShield',plaque(outline,[(.94,0),(1,.4*scale),(1,.9*scale),(.94,1.5*scale)],warp),GOLD,socket,'metal')
    add(prefix+'Enamel',plaque(outline*.79,[(.98,1.5*scale),(1,1.7*scale),(.96,1.95*scale)],warp),NAVY,socket)
    # The star is a raised relief, not a round colored center.
    emblem=star(5.7*scale)+[0,2.4*scale]
    add(prefix+'Star',plaque(emblem,[(.96,2*scale),(1,2.4*scale),(.88,2.9*scale)],warp),SILVER,socket,'metal')
    if scale>.6:
        # Two short service bars remain legible below the star at pet size.
        for i in range(2):
            bar=np.array([[-3.6,-5-i*2],[3.6,-5-i*2],[3.6,-4.1-i*2],[-3.6,-4.1-i*2]])*scale
            add(prefix+f'ServiceBar{i}',plaque(bar,[(1,2.0*scale),(1,2.45*scale)],warp),GOLD,socket,'metal')
# Slight curvature follows the chest rather than leaving an oval floating off it.
data=(ROOT/'Unreal/MuseGuard/Content/Muse/Jolly.musemesh').read_bytes()
count=struct.unpack_from('<I',data,12)[0]
body=np.frombuffer(data,dtype='<f4',offset=32,count=count*18).reshape(count,18)[:,:3]
front=body[(body[:,0]>15)&(body[:,2]>40)&(body[:,2]<78)]
tree=cKDTree(front[:,1:3])
def fitted_chest(d,y,z):
    yy,zz=-13+y,60+z
    distance,index=tree.query([yy,zz],k=8)
    weight=1/np.maximum(distance,.1)**2
    xx=np.sum(front[index,0]*weight)/weight.sum()
    return [xx+1.2+d,yy,zz]
badge('Chest',1.05,fitted_chest,'body')
badge('Cap',.40,lambda d,y,z:[25.5+d-.12*z,y,43.5+z],'head')
# Guard outfit is the fitted cap and chest insignia. The legacy ellipsoid
# cape intersected the plush torso and appeared as a dark slit from the side.
output=ROOT/'Unreal/MuseGuard/Content/Muse/GuardAccessories.json'
output.write_text(json.dumps({'version':1,'meshes':meshes},separators=(',',':'))+'\n')
config=ROOT/'Unreal/MuseGuard/Config/MuseAccessories.json';j=json.loads(config.read_text());j['accessories'][0]['parts']=parts;config.write_text(json.dumps(j,indent=2)+'\n')
print(f'{len(meshes)} fitted meshes; {sum(len(m["indices"])//3 for m in meshes.values()):,} triangles; {output.stat().st_size:,} bytes')
