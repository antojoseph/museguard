#!/usr/bin/env python3
"""Check the committed runtime mesh against its original STL and attribution."""
from pathlib import Path
from collections import Counter
import hashlib, json, math, struct
root=Path(__file__).resolve().parents[1]
path=root/'Unreal/MuseGuard/Content/Muse/Jolly.musemesh'
meta=json.loads(path.with_suffix('.json').read_text())
source=root/meta['source']
assert hashlib.sha256(source.read_bytes()).hexdigest()==meta['source_sha256']
b=path.read_bytes(); offset=0
def read(fmt):
    global offset
    result=struct.unpack_from(fmt,b,offset); offset+=struct.calcsize(fmt); return result
assert read('<III')==(0x4D55534B,3,3)
triangles=0
bounds=[[float('inf')]*3,[-float('inf')]*3]
for section in range(3):
    count,indices,*color=read('<II3f')
    assert 0<count<=100000 and 0<indices<=600000 and indices%3==0
    assert all(0<=c<=1 for c in color)
    for _ in range(count):
        v=read('<18f')
        assert all(math.isfinite(n) for n in v)
        assert abs(sum(w for w in v[6:])-1)<1e-5
        assert all(-1e-6<=w<=1.000001 for w in v[6:])
        assert abs(sum(n*n for n in v[3:6])-1)<1e-4
        for i in range(3): bounds[0][i]=min(bounds[0][i],v[i]);bounds[1][i]=max(bounds[1][i],v[i])
    idx=read(f'<{indices}I')
    assert min(idx)>=0 and max(idx)<count
    edges=Counter()
    for i in range(0,indices,3):
        va,vb,vc=idx[i:i+3]
        edges.update([tuple(sorted((va,vb))),tuple(sorted((vb,vc))),tuple(sorted((vc,va)))])
    assert all(count==2 for count in edges.values()), f'Open or non-manifold section {section}'
    triangles+=indices//3
assert offset==len(b), 'Trailing or incorrectly counted mesh data'
assert triangles==meta['triangles']
assert meta['source_triangles']==struct.unpack_from('<I',source.read_bytes(),80)[0]
assert meta['closed_parts']==7 and meta['articulated_body_parts']==3
assert 122<bounds[1][2]<124 and abs(bounds[0][2])<.01
assert meta['license']=='CC BY-NC-SA 4.0' and len(meta['bones'])==12
print(f'Muse source, attribution, topology, normals and skin weights passed ({triangles:,} triangles).')
