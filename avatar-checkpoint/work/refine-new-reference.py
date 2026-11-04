import bpy, math, bmesh
from mathutils import Vector
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/'
# Replace only the character geometry; keep studio, saved checkpoints and camera.
for name in ['Coat','Face','Eye_L','Eye_R','Glint_L','Glint_R','Mouth','Blush_L','Blush_R','Arm_L','Arm_R','Foot_L','Foot_R']:
 ob=bpy.data.objects.get(name)
 if ob:bpy.data.objects.remove(ob,do_unlink=True)
for ob in list(bpy.data.objects):
 if ob.name.endswith('_PlushGroom'):bpy.data.objects.remove(ob,do_unlink=True)
def lin(v):return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
def rgb(h):return tuple(lin(int(h[i:i+2],16)/255) for i in (0,2,4))
def bsdf(name,color,rough=.65):
 m=bpy.data.materials.get(name) or bpy.data.materials.new(name);m.use_nodes=True
 node=next((n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED'),None)
 if node is None:
  m.node_tree.nodes.clear();out=m.node_tree.nodes.new('ShaderNodeOutputMaterial');node=m.node_tree.nodes.new('ShaderNodeBsdfPrincipled');m.node_tree.links.new(node.outputs[0],out.inputs['Surface'])
 node.inputs['Base Color'].default_value=(*rgb(color),1);node.inputs['Roughness'].default_value=rough;m.diffuse_color=(*rgb(color),1)
 return m,node
coatmat,_=bsdf('CoatMat','DCC8A7',.82)
skinmat,skin=bsdf('FaceMat','F5DDB9',.66)
skin.inputs['Subsurface Weight'].default_value=.07;skin.inputs['Specular IOR Level'].default_value=.20
noise=skinmat.node_tree.nodes.get('SoftSkinGrain') or skinmat.node_tree.nodes.new('ShaderNodeTexNoise');noise.name='SoftSkinGrain';noise.inputs['Scale'].default_value=160
bump=skinmat.node_tree.nodes.get('SkinMicroBump') or skinmat.node_tree.nodes.new('ShaderNodeBump');bump.name='SkinMicroBump';bump.inputs['Strength'].default_value=.045;bump.inputs['Distance'].default_value=.001
skinmat.node_tree.links.new(noise.outputs['Fac'],bump.inputs['Height']);skinmat.node_tree.links.new(bump.outputs['Normal'],skin.inputs['Normal'])
eyemat,eye=bsdf('EyeMat','10100F',.16);eye.inputs['Specular IOR Level'].default_value=.25
mouthmat,_=bsdf('MouthMat','29241E',.7);white,_=bsdf('GlintMat','FFFFFF',.25)
profile=[(.22,.12,.14),(.25,.28,.25),(.34,.41,.33),(.53,.51,.39),(.82,.54,.40),(1.10,.50,.38),(1.35,.47,.38),(1.62,.475,.375),(1.82,.415,.32),(1.95,.28,.235),(1.995,.075,.07)]
def value(z,k):
 for i in range(len(profile)-1):
  if z<=profile[i+1][0]:break
 p=profile[i];q=profile[i+1];l=profile[max(0,i-1)];r=profile[min(len(profile)-1,i+2)];dt=q[0]-p[0];t=max(0,min(1,(z-p[0])/dt));m0=(q[k]-l[k])/(q[0]-l[0]);m1=(r[k]-p[k])/(r[0]-p[0])
 return max(.001,(2*t**3-3*t*t+1)*p[k]+(t**3-2*t*t+t)*dt*m0+(-2*t**3+3*t*t)*q[k]+(t**3-t*t)*dt*m1)
def expo(z):return 2.4+max(0,min(1,(z-1.05)/.3))
def head_y(x,z):
 rx=value(z,1);ry=value(z,2);n=expo(z)
 return -ry*max(.001,1-min(.9999,abs(x)/rx)**n)**(1/n)
def normal(x,z):
 e=.001;dx=(head_y(x+e,z)-head_y(x-e,z))/(2*e);dz=(head_y(x,z+e)-head_y(x,z-e))/(2*e)
 return Vector((dx,-1,dz)).normalized()
cz=1.55;depth=.022
outerA=.425;outerB=.312;innerA=.39;innerB=.279
def power(z):return 2.20 if z>=cz else 3.85
def rr(x,z):
 n=power(z);return (abs(x/outerA)**n+abs((z-cz)/outerB)**n)**(1/n)
def superpoint(t,a,b):
 c=math.cos(t);s=math.sin(t);n=2.20 if s>=0 else 3.85
 return a*math.copysign(abs(c)**(2/n),c),cz+b*math.copysign(abs(s)**(2/n),s)
def skinpoint(x,z):return Vector((x,head_y(x,z)+depth,z))
def mesh(name,V,F,mat):
 me=bpy.data.meshes.new(name+'Mesh');me.from_pydata(V,[],F);me.update();ob=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(ob);me.materials.append(mat)
 bm=bmesh.new();bm.from_mesh(me);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(me);bm.free()
 for p in me.polygons:p.use_smooth=True
 return ob
# Continuous coat with a single clean boundary and an integral, fur-covered rolled lip.
V=[];F=[];weights=[];nr=152;nt=176
for j in range(nr):
 z=.22+(1.995-.22)*j/(nr-1);rx=value(z,1);ry=value(z,2);n=expo(z)
 for i in range(nt):
  t=2*math.pi*i/nt;V.append([rx*math.copysign(abs(math.cos(t))**(2/n),math.cos(t)),ry*math.copysign(abs(math.sin(t))**(2/n),math.sin(t)),z]);weights.append(1)
for j in range(nr-1):
 for i in range(nt):
  ids=[j*nt+i,j*nt+(i+1)%nt,(j+1)*nt+(i+1)%nt,(j+1)*nt+i]
  c=[sum(V[k][a] for k in ids)/4 for a in range(3)]
  if c[1]<0 and rr(c[0],c[2])<1:continue
  F.append(ids)
V.append([0,0,.205]);weights.append(1);bot=len(V)-1;V.append([0,0,2]);weights.append(1);top=len(V)-1
for i in range(nt):F.append([bot,(i+1)%nt,i]);F.append([top,(nr-1)*nt+i,(nr-1)*nt+(i+1)%nt])
counts={}
for f in F:
 for a,b in zip(f,f[1:]+f[:1]):
  key=tuple(sorted((a,b)));counts[key]=counts.get(key,0)+1
boundary=set()
for (a,b),cnt in counts.items():
 if cnt==1:boundary.add(a);boundary.add(b)
ordered=sorted(boundary,key=lambda k:math.atan2((V[k][2]-cz)/outerB,V[k][0]/outerA))
for k in ordered:
 x,y,z=V[k];r=rr(x,z);x/=r;z=cz+(z-cz)/r;V[k]=[x,head_y(x,z),z]
prev=ordered
for layer in range(1,11):
 t=layer/10;ids=[]
 for k in ordered:
  x,_,z=V[k];xx=x/outerA*(outerA+(innerA-outerA)*t);zz=cz+(z-cz)/outerB*(outerB+(innerB-outerB)*t)
  yy=head_y(xx,zz)-.012*math.sin(math.pi*t)
  if t>.70:yy+=depth*((t-.70)/.30)**2
  ids.append(len(V));V.append([xx,yy,zz]);weights.append(max(0,min(1,(.91-t)/.18)))
 for i in range(len(ids)):F.append([prev[i],prev[(i+1)%len(ids)],ids[(i+1)%len(ids)],ids[i]])
 prev=ids
coat=mesh('Coat',V,F,coatmat);group=coat.vertex_groups.new(name='FurDensity')
for i,w in enumerate(weights):group.add([i],w,'REPLACE')
# Wider, slightly raised face, conforming to the actual head curvature.
sv=[list(skinpoint(0,cz))];sf=[];rings=26;segments=112
for j in range(1,rings+1):
 r=j/rings
 for i in range(segments):
  x,z=superpoint(2*math.pi*i/segments,innerA*r,innerB*r);sv.append(list(skinpoint(x,z)))
for i in range(segments):sf.append([0,1+i,1+(i+1)%segments])
for j in range(1,rings):
 a=1+(j-1)*segments;b=1+j*segments
 for i in range(segments):sf.append([a+i,b+i,b+(i+1)%segments,a+(i+1)%segments])
face=mesh('Face',sv,sf,skinmat);solid=face.modifiers.new('Buried skin thickness','SOLIDIFY');solid.thickness=.012;solid.offset=-1
face['RefinedRecessDepth']=depth
for side,sgn in [('L',-1),('R',1)]:
 x=sgn*.19;z=1.55;n=normal(x,z);p=skinpoint(x,z)+n*.008
 bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=32,radius=1,location=p)
 eyeob=bpy.context.object;eyeob.name='Eye_'+side;eyeob.scale=(.040,.022,.042);eyeob.rotation_mode='QUATERNION';eyeob.rotation_quaternion=Vector((0,-1,0)).rotation_difference(n);eyeob.data.materials.append(eyemat)
 for poly in eyeob.data.polygons:poly.use_smooth=True
 bpy.ops.mesh.primitive_uv_sphere_add(segments=16,ring_count=8,radius=.0028,location=p+n*.023+Vector((-.010,0,.014)))
 gl=bpy.context.object;gl.name='Glint_'+side;gl.data.materials.append(white)
cu=bpy.data.curves.new('SmileCurve','CURVE');cu.dimensions='3D';cu.resolution_u=24;cu.bevel_depth=.0048;cu.bevel_resolution=4
sp=cu.splines.new('POLY');sp.points.add(32)
for i in range(33):
 x=-.060+.120*i/32;z=1.440+.022*(x/.06)**2;p=skinpoint(x,z)+normal(x,z)*.003;sp.points[i].co=(*p,1)
ob=bpy.data.objects.new('Mouth',cu);bpy.context.collection.objects.link(ob);cu.materials.append(mouthmat)
# Peach cheeks, gently feathered across the same curved face.
blush=bpy.data.materials['SoftBlush'];bn=blush.node_tree.nodes;pink=next(n for n in bn if n.type=='BSDF_PRINCIPLED');pink.inputs['Base Color'].default_value=(*rgb('F2A49A'),1);pink.inputs['Roughness'].default_value=.76
for side,sgn in [('L',-1),('R',1)]:
 vv=[];ff=[];aa=[];N=64;R=12
 for j in range(R+1):
  r=max(.00001,j/R)
  for i in range(N):
   t=2*math.pi*i/N;x=sgn*.255+.085*r*math.cos(t);z=1.445+.066*r*math.sin(t)
   p=skinpoint(x,z)+normal(x,z)*.0012;vv.append(list(p));aa.append(.52*(1-r*r)**2)
 for j in range(R):
  for i in range(N):ff.append([j*N+i,(j+1)*N+i,(j+1)*N+(i+1)%N,j*N+(i+1)%N])
 ob=mesh('Blush_'+side,vv,ff,blush);attr=ob.data.color_attributes.new(name='BlushTint',type='FLOAT_COLOR',domain='POINT')
 for i,a in enumerate(aa):attr.data[i].color=(1,1,1,a)
# Longer hanging arms, with a gentle outward shoulder sweep and rounded mitten ends.
def arm(side,sgn):
 keys=[(0,.425,.025,1.33,.050,.080),(.14,.505,.015,1.23,.095,.135),(.37,.625,-.020,1.04,.115,.150),(.64,.705,-.070,.76,.124,.155),(.85,.735,-.120,.50,.115,.140),(.96,.725,-.150,.39,.065,.090),(1,.712,-.160,.365,.006,.010)]
 def val(t,k):
  for j in range(len(keys)-1):
   if t<=keys[j+1][0]:break
  p=keys[j];q=keys[j+1];l=keys[max(0,j-1)];r=keys[min(len(keys)-1,j+2)];u=(t-p[0])/(q[0]-p[0]);dt=q[0]-p[0];m0=(q[k]-l[k])/(q[0]-l[0]);m1=(r[k]-p[k])/(r[0]-p[0])
  return (2*u**3-3*u*u+1)*p[k]+(u**3-2*u*u+u)*dt*m0+(-2*u**3+3*u*u)*q[k]+(u**3-u*u)*dt*m1
 def center(t):return Vector((sgn*val(t,1),val(t,2),val(t,3)))
 V=[];F=[];nr=64;ns=48
 for j in range(nr):
  t=j/(nr-1);p=center(t);tan=(center(min(1,t+.001))-center(max(0,t-.001))).normalized();ex=Vector((0,1,0)).cross(tan).normalized();ey=tan.cross(ex).normalized();rx=max(.005,val(t,4));ry=max(.005,val(t,5))
  for i in range(ns):
   a=2*math.pi*i/ns;V.append(tuple(p+ex*(rx*math.cos(a))+ey*(ry*math.sin(a))))
 for j in range(nr-1):
  for i in range(ns):F.append([j*ns+i,j*ns+(i+1)%ns,(j+1)*ns+(i+1)%ns,(j+1)*ns+i])
 F.append(list(reversed(range(ns))));F.append([(nr-1)*ns+i for i in range(ns)])
 return mesh('Arm_'+side,V,F,coatmat)
def foot(side,sgn):
 rings=[(.012,.120,.130),(.022,.145,.160),(.055,.160,.177),(.130,.160,.175),(.220,.155,.170),(.310,.150,.150),(.365,.110,.120)];V=[];F=[];ns=64
 for z,rx,ry in rings:
  for i in range(ns):
   a=2*math.pi*i/ns;n=3.;x=sgn*.23+rx*math.copysign(abs(math.cos(a))**(2/n),math.cos(a));y=-.015+ry*math.copysign(abs(math.sin(a))**(2/n),math.sin(a))
   if z<.16:y-=.025*(1-z/.16)
   V.append((x,y,z))
 for j in range(len(rings)-1):
  for i in range(ns):F.append([j*ns+i,j*ns+(i+1)%ns,(j+1)*ns+(i+1)%ns,(j+1)*ns+i])
 F.append(list(reversed(range(ns))));F.append([(len(rings)-1)*ns+i for i in range(ns)])
 ob=mesh('Foot_'+side,V,F,coatmat);sub=ob.modifiers.new('Soft paw smoothing','SUBSURF');sub.levels=1;sub.render_levels=1
 vg=ob.vertex_groups.new(name='NoSoleFur')
 for v in ob.data.vertices:vg.add([v.index],max(0,min(1,(v.co.z-.012)/.035)),'REPLACE')
 return ob
for side,sgn in [('L',-1),('R',1)]:arm(side,sgn);foot(side,sgn)
# An almost frontal product view, matching the reference instead of foreshortening the face.
scene=bpy.context.scene;cam=scene.camera;cam.location=(.10,-4,1.22);cam.rotation_euler=(Vector((0,0,1.02))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=2.46
scene.render.resolution_x=800;scene.render.resolution_y=900;scene.cycles.samples=32
scene.render.filepath=root+'work/proportion-preview.png'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=root+'work/reference-refinement-stage.blend')
bpy.ops.render.render(write_still=True)
print('Reference proportions: wider raised curved face, connected hood, longer tapered arms and broader short feet. Stage saved.')
