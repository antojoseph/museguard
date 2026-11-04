import bpy, math
from mathutils import Vector
# Rebuild the head/coat as a real open surface; keep the existing studio.
for name in ['Coat','HoodRim','Face','Eye_L','Eye_R','Glint_L','Glint_R','Mouth','Blush_L','Blush_R']:
    ob=bpy.data.objects.get(name)
    if ob: bpy.data.objects.remove(ob,do_unlink=True)
def lin(v): return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
def rgb(h): return tuple(lin(int(h[i:i+2],16)/255) for i in (0,2,4))
def material(name,h,rough=.6):
    m=bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes=True; m.node_tree.nodes.clear()
    out=m.node_tree.nodes.new('ShaderNodeOutputMaterial'); bs=m.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
    col=rgb(h); bs.inputs['Base Color'].default_value=(*col,1); bs.inputs['Roughness'].default_value=rough
    bs.inputs['Metallic'].default_value=0; m.diffuse_color=(*col,1)
    m.node_tree.links.new(bs.outputs['BSDF'],out.inputs['Surface'])
    return m,bs
coatmat,bs=material('CoatMat','E8DCCB',.75)
if 'Sheen Weight' in bs.inputs: bs.inputs['Sheen Weight'].default_value=.25
noise=coatmat.node_tree.nodes.new('ShaderNodeTexNoise'); noise.inputs['Scale'].default_value=180
bump=coatmat.node_tree.nodes.new('ShaderNodeBump'); bump.inputs['Strength'].default_value=.13;bump.inputs['Distance'].default_value=.002
coatmat.node_tree.links.new(noise.outputs['Fac'],bump.inputs['Height']);coatmat.node_tree.links.new(bump.outputs['Normal'],bs.inputs['Normal'])
skinmat,skinbs=material('FaceMat','F7E6D6',.62)
if 'Subsurface Weight' in skinbs.inputs: skinbs.inputs['Subsurface Weight'].default_value=.08
if 'Specular IOR Level' in skinbs.inputs: skinbs.inputs['Specular IOR Level'].default_value=.22
eyemat,eyebs=material('EyeMat','10100F',.18)
if 'Specular IOR Level' in eyebs.inputs: eyebs.inputs['Specular IOR Level'].default_value=.22
mouthmat,_=material('MouthMat','29241E',.7)
white,_=material('GlintMat','FFFFFF',.25)
hairmat=bpy.data.materials.get('PlushHair') or bpy.data.materials.new('PlushHair');hairmat.use_nodes=True;hairmat.node_tree.nodes.clear()
out=hairmat.node_tree.nodes.new('ShaderNodeOutputMaterial');hair=hairmat.node_tree.nodes.new('ShaderNodeBsdfHairPrincipled')
try: hair.parametrization='COLOR'
except: pass
if 'Color' in hair.inputs: hair.inputs['Color'].default_value=(*rgb('E8DCCB'),1)
if 'Roughness' in hair.inputs: hair.inputs['Roughness'].default_value=.42
if 'Radial Roughness' in hair.inputs: hair.inputs['Radial Roughness'].default_value=.55
hairmat.node_tree.links.new(hair.outputs[0],out.inputs['Surface'])
profile=[(.22,.12,.14),(.25,.28,.25),(.34,.41,.33),(.53,.51,.39),(.82,.54,.40),(1.10,.50,.38),(1.35,.45,.38),(1.62,.445,.375),(1.82,.39,.32),(1.95,.26,.235),(1.995,.07,.07)]
def profile_value(z,k):
    for i in range(len(profile)-1):
        if z<=profile[i+1][0]: break
    p=profile[i];q=profile[i+1]; dz=q[0]-p[0];t=max(0,min(1,(z-p[0])/dz))
    left=profile[max(0,i-1)];right=profile[min(len(profile)-1,i+2)]
    m0=(q[k]-left[k])/(q[0]-left[0]);m1=(right[k]-p[k])/(right[0]-p[0])
    return max(.001,(2*t**3-3*t*t+1)*p[k]+(t**3-2*t*t+t)*dz*m0+(-2*t**3+3*t*t)*q[k]+(t**3-t*t)*dz*m1)
def expo(z): return 2.4+1.0*max(0,min(1,(z-1.05)/.3))
def head_y(x,z):
    rx=profile_value(z,1);ry=profile_value(z,2);n=expo(z)
    return -ry*max(.001,1-min(.9999,abs(x)/rx)**n)**(1/n)
def normal(x,z):
    e=.001;dx=(head_y(x+e,z)-head_y(x-e,z))/(2*e);dz=(head_y(x,z+e)-head_y(x,z-e))/(2*e)
    return Vector((dx,-1,dz)).normalized()
def skinpoint(x,z): return Vector((x,head_y(x,z)+.032,z))
def rr(x,z,a=.40,b=.345): return (abs(x/a)**3+abs((z-1.48)/b)**3)**(1/3)
def superpoint(t,a,b): return (a*math.copysign(abs(math.cos(t))**(2/3),math.cos(t)),1.48+b*math.copysign(abs(math.sin(t))**(2/3),math.sin(t)))
V=[];F=[];weights=[];nr=136;nt=160;z0=profile[0][0];z1=profile[-1][0]
for j in range(nr):
    z=z0+(z1-z0)*j/(nr-1);rx=profile_value(z,1);ry=profile_value(z,2);n=expo(z)
    for i in range(nt):
        t=2*math.pi*i/nt;V.append([rx*math.copysign(abs(math.cos(t))**(2/n),math.cos(t)),ry*math.copysign(abs(math.sin(t))**(2/n),math.sin(t)),z]);weights.append(1)
for j in range(nr-1):
    for i in range(nt):
        ids=[j*nt+i,j*nt+(i+1)%nt,(j+1)*nt+(i+1)%nt,(j+1)*nt+i]
        c=[sum(V[k][a] for k in ids)/4 for a in range(3)]
        if c[1]<0 and rr(c[0],c[2])<1:continue
        F.append(ids)
V.append([0,0,.205]);weights.append(1);bot=len(V)-1
V.append([0,0,2]);weights.append(1);top=len(V)-1
for i in range(nt): F.append([bot,(i+1)%nt,i]);F.append([top,(nr-1)*nt+i,(nr-1)*nt+(i+1)%nt])
# Locate the single cut boundary and snap it to an exact superellipse.
counts={}
for f in F:
    for a,b in zip(f,f[1:]+f[:1]):
        key=tuple(sorted((a,b)));counts[key]=counts.get(key,0)+1
boundary=set()
for (a,b),count in counts.items():
    if count==1:boundary.add(a);boundary.add(b)
ordered=sorted(boundary,key=lambda k:math.atan2((V[k][2]-1.48)/.345,V[k][0]/.40))
for k in ordered:
    x,y,z=V[k];r=rr(x,z);x=x/r;z=1.48+(z-1.48)/r;V[k]=[x,head_y(x,z),z]
# Smooth integral lip followed by a short inward wall: no separate picture frame.
prev=ordered
for layer in range(1,10):
    t=layer/9;ids=[]
    for k in ordered:
        x,_,z=V[k];a=.40+(.36-.40)*t;b=.345+(.305-.345)*t
        xx=x/.40*a;zz=1.48+(z-1.48)/.345*b
        yy=head_y(xx,zz)-.014*math.sin(math.pi*t)
        if t>.72:yy+=.032*((t-.72)/.28)**2
        ids.append(len(V));V.append([xx,yy,zz]);weights.append(max(0,min(1,(.83-t)/.18)))
    for i in range(len(ids)):F.append([prev[i],prev[(i+1)%len(ids)],ids[(i+1)%len(ids)],ids[i]])
    prev=ids
# Consistent winding and normal recalculation after mesh creation.
def meshob(name,verts,faces,mat):
    me=bpy.data.meshes.new(name+'Mesh');me.from_pydata(verts,[],faces);me.update()
    ob=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(ob);me.materials.append(mat)
    for p in me.polygons:p.use_smooth=True
    return ob
coat=meshob('Coat',V,F,coatmat)
# Recalculate coherent outward normals.
import bmesh
bm=bmesh.new();bm.from_mesh(coat.data);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(coat.data);bm.free()
group=coat.vertex_groups.new(name='FurDensity')
for i,w in enumerate(weights):group.add([i],w,'REPLACE')
# Curved skin follows the original head surface, recessed by 32 mm.
sv=[list(skinpoint(0,1.48))];sf=[];rings=22;segments=96
for j in range(1,rings+1):
    r=j/rings
    for i in range(segments):
        x,z=superpoint(2*math.pi*i/segments,.36*r,.305*r);sv.append(list(skinpoint(x,z)))
for i in range(segments):sf.append([0,1+i,1+(i+1)%segments])
for j in range(1,rings):
    inner=1+(j-1)*segments;outer=1+j*segments
    for i in range(segments):sf.append([inner+i,outer+i,outer+(i+1)%segments,inner+(i+1)%segments])
face=meshob('Face',sv,sf,skinmat)
solid=face.modifiers.new('Buried skin thickness','SOLIDIFY');solid.thickness=.012;solid.offset=-1
# Correct the already-built limbs and give all emitters consistent materials.
for side,sgn in [('L',-1),('R',1)]:
    foot=bpy.data.objects.get('Foot_'+side)
    if foot:
        foot.location=(sgn*.22,-.015,.145);foot.rotation_euler=(0,0,0);foot.dimensions=(.31,.38,.27)
        foot.data.materials.clear();foot.data.materials.append(coatmat)
    arm=bpy.data.objects.get('Arm_'+side)
    if arm:
        arm.location=(sgn*.575,-.035,.96);arm.rotation_euler=(0,-sgn*.20,0);arm.dimensions=(.255,.32,.50)
        arm.data.materials.clear();arm.data.materials.append(coatmat)
    x=sgn*.18;z=1.505;n=normal(x,z);p=skinpoint(x,z)+n*.008
    bpy.ops.mesh.primitive_uv_sphere_add(segments=40,ring_count=24,radius=1,location=p)
    eye=bpy.context.object;eye.name='Eye_'+side;eye.scale=(.041,.022,.041);eye.rotation_mode='QUATERNION';eye.rotation_quaternion=Vector((0,-1,0)).rotation_difference(n)
    eye.data.materials.append(eyemat)
    for poly in eye.data.polygons:poly.use_smooth=True
    gl=p+n*.023+Vector((-.010,0,.014))
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16,ring_count=8,radius=.0035,location=gl)
    glint=bpy.context.object;glint.name='Glint_'+side;glint.data.materials.append(white)
# Smile rests directly on the curved cheek surface.
cu=bpy.data.curves.new('SmileCurve','CURVE');cu.dimensions='3D';cu.resolution_u=24;cu.bevel_depth=.005;cu.bevel_resolution=4
sp=cu.splines.new('POLY');sp.points.add(24)
for i in range(25):
    x=-.07+.14*i/24;z=1.365+.022*(x/.07)**2;p=skinpoint(x,z)+normal(x,z)*.003;sp.points[i].co=(*p,1)
ob=bpy.data.objects.new('Mouth',cu);bpy.context.collection.objects.link(ob);cu.materials.append(mouthmat)
# Feathered blush follows the same sampled head curve.
blush=bpy.data.materials.get('SoftBlush') or bpy.data.materials.new('SoftBlush');blush.use_nodes=True;blush.node_tree.nodes.clear()
bn=blush.node_tree.nodes;bl=blush.node_tree.links;out=bn.new('ShaderNodeOutputMaterial');mix=bn.new('ShaderNodeMixShader');trans=bn.new('ShaderNodeBsdfTransparent');pink=bn.new('ShaderNodeBsdfPrincipled');pink.inputs['Base Color'].default_value=(*rgb('F7B6B6'),1);pink.inputs['Roughness'].default_value=.7
att=bn.new('ShaderNodeVertexColor');att.layer_name='BlushTint';bl.new(att.outputs['Alpha'],mix.inputs[0]);bl.new(trans.outputs[0],mix.inputs[1]);bl.new(pink.outputs[0],mix.inputs[2]);bl.new(mix.outputs[0],out.inputs['Surface'])
for side,sgn in [('L',-1),('R',1)]:
    vv=[];ff=[];aa=[];N=48;R=8
    for j in range(R+1):
        r=max(.00001,j/R)
        for i in range(N):
            t=2*math.pi*i/N;x=sgn*.24+.070*r*math.cos(t);z=1.405+.052*r*math.sin(t)
            p=skinpoint(x,z)+normal(x,z)*.0015;vv.append(list(p));aa.append(.34*(1-r*r)**2)
    for j in range(R):
        for i in range(N):ff.append([j*N+i,(j+1)*N+i,(j+1)*N+(i+1)%N,j*N+(i+1)%N])
    ob=meshob('Blush_'+side,vv,ff,blush);attr=ob.data.color_attributes.new(name='BlushTint',type='FLOAT_COLOR',domain='POINT')
    for i,a in enumerate(aa):attr.data[i].color=(1,1,1,a)
# Dense, short, straight plush, with finer tips and no carpet curls.
def fur(ob,count):
    bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    for p in list(ob.particle_systems):bpy.ops.object.particle_system_remove()
    ob.data.materials.append(hairmat);bpy.ops.object.particle_system_add();ps=ob.particle_systems[-1];s=ps.settings
    s.type='HAIR';s.count=count;s.hair_length=.024;s.hair_step=3;s.child_type='INTERPOLATED';s.child_percent=12;s.rendered_child_count=45;s.material=len(ob.data.materials)
    s.length_random=.22;s.clump_factor=.07;s.kink='NO';s.roughness_1=.003;s.roughness_2=.002;s.roughness_endpoint=.001
    s.root_radius=.35;s.tip_radius=.06;s.radius_scale=.0017
    if ob.name=='Coat':ps.vertex_group_density='FurDensity'
fur(coat,4500)
for n in ['Arm_L','Arm_R']:fur(bpy.data.objects[n],850)
for n in ['Foot_L','Foot_R']:fur(bpy.data.objects[n],550)
# Studio and framing.
ground=bpy.data.objects.get('Ground')
if ground:ground.location.z=-.015;ground.hide_render=False
scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.samples=24;scene.cycles.use_denoising=True
scene.view_settings.view_transform='AgX';scene.view_settings.exposure=.15;scene.view_settings.gamma=1
world=scene.world;world.use_nodes=True;bg=world.node_tree.nodes.get('Background')
if bg:bg.inputs['Color'].default_value=(1,1,1,1);bg.inputs['Strength'].default_value=.7
for name,power in [('KeyLight',240),('FillLight',110),('RimLight',140)]:
    ob=bpy.data.objects.get(name)
    if ob:ob.data.energy=power;ob.data.size=2.0
sun=bpy.data.objects.get('Sun')
if sun:sun.hide_render=True
cam=scene.camera;cam.location=(.70,-4,1.28);cam.rotation_euler=(Vector((0,0,1.04))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=2.45
scene.render.resolution_x=640;scene.render.resolution_y=640;scene.render.resolution_percentage=100;scene.render.film_transparent=False
scene.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.png'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.blend')
print('Repaired continuous coat opening: boundary',len(ordered),'coat vertices',len(V),'skin vertices',len(sv),'actual inset 32mm following head curvature. Scene saved.')
