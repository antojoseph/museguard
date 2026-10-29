#!/usr/bin/env python3
"""Check the cap shell against the actual hood, including short fur clearance."""
from collections import Counter
import json, math, struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
meshes=json.loads((ROOT/'Unreal/MuseGuard/Content/Muse/GuardAccessories.json').read_text())['meshes']

def rings(name):
    levels={}
    for x,y,z in meshes[name]['vertices']: levels.setdefault(z,[]).append((x,y))
    result=[]
    for z,points in sorted(levels.items()):
        lo=min(x for x,y in points);hi=max(x for x,y in points)
        result.append((z,(lo+hi)/2,(hi-lo)/2,max(abs(y) for x,y in points)))
    return result

def profile(rows,z):
    for a,b in zip(rows,rows[1:]):
        if a[0]-1e-5<=z<=b[0]+1e-5:
            t=(z-a[0])/(b[0]-a[0]);return [a[i]+t*(b[i]-a[i]) for i in range(1,4)]
    return None

def clearance(rows,p):
    shape=profile(rows,p[2])
    if shape is None:return -math.inf
    cx,rx,ry=shape
    return (1-math.hypot((p[0]-cx)/rx,p[1]/ry))*min(rx,ry)

band,crown=rings('CapBand'),rings('CapCrown')
assert band[-1][0]-crown[0][0]>=.5,'Band and crown must overlap'
for name in ['CapBand','CapCrown','CurvedVisor']:
    mesh=meshes[name];indices=mesh['indices'];edges=Counter()
    for i in range(0,len(indices),3):
        a,b,c=indices[i:i+3];edges.update([tuple(sorted((a,b))),tuple(sorted((b,c))),tuple(sorted((c,a)))])
    assert edges and all(n==2 for n in edges.values()),f'Open cap surface: {name}'

raw=(ROOT/'Unreal/MuseGuard/Content/Muse/Jolly.musemesh').read_bytes()
count=struct.unpack_from('<I',raw,12)[0];tested=0;minimum=math.inf
for i in range(count):
    v=struct.unpack_from('<18f',raw,32+72*i)
    if v[2]<78+band[0][0]:continue
    assert v[7]>.999,'Cap and hood must share the same head transform'
    # Normals expand the hood into its short fur coat. The moving cap must
    # enclose this shell, rather than intersect its bare mesh underneath.
    p=[v[j]+1.6*v[j+3] for j in range(3)];p[2]-=78
    gap=max(clearance(band,p),clearance(crown,p))
    assert gap>.05,f'Hood/fur protrudes through cap at {p}: margin {gap:.3f}'
    minimum=min(minimum,gap);tested+=1
assert tested>100
for name in ['CapGoldShield','CapEnamel','CapStar']:
    for x,y,z in meshes[name]['vertices']:
        cx,rx,ry=profile(crown,z)
        front=cx+rx*math.sqrt(max(0,1-(y/ry)**2))
        assert x>=front+.25,f'Badge buried in crown: {name}'
print(f'PASS: closed cap, overlapping band/crown, {tested} fur-expanded hood vertices enclosed (min margin {minimum:.2f}), exposed badge')
