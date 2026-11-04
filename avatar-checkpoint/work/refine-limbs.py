import bpy, math
from mathutils import Vector
coatmat=bpy.data.materials['CoatMat'];hairmat=bpy.data.materials['PlushHair']
for n in ['Arm_L','Arm_R','Foot_L','Foot_R']:
    o=bpy.data.objects.get(n)
    if o:bpy.data.objects.remove(o,do_unlink=True)
def make_mesh(name,V,F):
    me=bpy.data.meshes.new(name+'Mesh');me.from_pydata(V,[],F);me.update();ob=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(ob);me.materials.append(coatmat)
    for p in me.polygons:p.use_smooth=True
    return ob
# Soft curved arm lofts: shoulder joins torso, round mittens hang down and forward.
def arm(side,sgn):
    keys=[(0,.43,-.005,1.22,.045,.070),(.18,.52,-.020,1.15,.105,.145),(.43,.605,-.055,1.01,.122,.155),(.70,.635,-.10,.86,.118,.15),(.88,.625,-.125,.77,.090,.115),(1,.61,-.13,.715,.008,.012)]
    def val(t,k):
        for j in range(len(keys)-1):
            if t<=keys[j+1][0]:break
        p=keys[j];q=keys[j+1];l=keys[max(0,j-1)];r=keys[min(len(keys)-1,j+2)];u=(t-p[0])/(q[0]-p[0]);dt=q[0]-p[0]
        m0=(q[k]-l[k])/(q[0]-l[0]);m1=(r[k]-p[k])/(r[0]-p[0])
        return (2*u**3-3*u*u+1)*p[k]+(u**3-2*u*u+u)*dt*m0+(-2*u**3+3*u*u)*q[k]+(u**3-u*u)*dt*m1
    def center(t):return Vector((sgn*val(t,1),val(t,2),val(t,3)))
    V=[];F=[];nr=38;ns=40
    for j in range(nr):
        t=j/(nr-1);p=center(t);tan=(center(min(1,t+.001))-center(max(0,t-.001))).normalized();ex=Vector((0,1,0)).cross(tan).normalized();ey=tan.cross(ex).normalized()
        rx=max(.005,val(t,4));ry=max(.005,val(t,5))
        for i in range(ns):
            a=2*math.pi*i/ns;v=p+ex*(rx*math.cos(a))+ey*(ry*math.sin(a));V.append(tuple(v))
    for j in range(nr-1):
        for i in range(ns):F.append([j*ns+i,j*ns+(i+1)%ns,(j+1)*ns+(i+1)%ns,(j+1)*ns+i])
    F.append(list(reversed(range(ns))));F.append([(nr-1)*ns+i for i in range(ns)])
    ob=make_mesh('Arm_'+side,V,F)
    import bmesh
    bm=bmesh.new();bm.from_mesh(ob.data);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(ob.data);bm.free()
    return ob
# Short plush legs with broad soft rounded-square paws and grounded soles.
def foot(side,sgn):
    rings=[(.013,.105,.125),(.022,.135,.160),(.055,.153,.183),(.100,.151,.183),(.165,.139,.165),(.235,.127,.145),(.290,.120,.135),(.325,.085,.100)]
    V=[];F=[];ns=56
    for z,rx,ry in rings:
        for i in range(ns):
            a=2*math.pi*i/ns;n=3.0
            x=sgn*.225+rx*math.copysign(abs(math.cos(a))**(2/n),math.cos(a));y=-.015+ry*math.copysign(abs(math.sin(a))**(2/n),math.sin(a))
            # Slightly project the toes toward the viewer.
            if z<.16:y-=.035*(1-z/.16)
            V.append((x,y,z))
    for j in range(len(rings)-1):
        for i in range(ns):F.append([j*ns+i,j*ns+(i+1)%ns,(j+1)*ns+(i+1)%ns,(j+1)*ns+i])
    F.append(list(reversed(range(ns))));F.append([(len(rings)-1)*ns+i for i in range(ns)])
    ob=make_mesh('Foot_'+side,V,F)
    import bmesh
    bm=bmesh.new();bm.from_mesh(ob.data);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(ob.data);bm.free()
    sub=ob.modifiers.new('Soft paw smoothing','SUBSURF');sub.levels=1;sub.render_levels=1
    return ob
def fur(ob,count):
    bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
    ob.data.materials.append(hairmat);bpy.ops.object.particle_system_add();ps=ob.particle_systems[-1];s=ps.settings
    s.type='HAIR';s.count=count;s.hair_length=.025;s.hair_step=3;s.child_type='INTERPOLATED';s.child_percent=12;s.rendered_child_count=45;s.material=2
    s.length_random=.20;s.clump_factor=.065;s.kink='NO';s.roughness_1=.003;s.roughness_2=.002;s.roughness_endpoint=.001;s.root_radius=.35;s.tip_radius=.06;s.radius_scale=.0017
    if ob.name.startswith('Foot'):
        vg=ob.vertex_groups.new(name='NoSoleFur')
        for v in ob.data.vertices:vg.add([v.index],max(0,min(1,(v.co.z-.012)/.035)),'REPLACE')
        ps.vertex_group_density=vg.name
for side,sgn in [('L',-1),('R',1)]:
    a=arm(side,sgn);f=foot(side,sgn);fur(a,1100);fur(f,850)
    print(a.name,'curved shoulder-to-mitten shape',tuple(round(v,3) for v in a.dimensions))
    print(f.name,'stubby leg and rounded flat sole',tuple(round(v,3) for v in f.dimensions))
ground=bpy.data.objects.get('Ground')
if ground:ground.location.z=0
scene=bpy.context.scene;scene.render.resolution_x=640;scene.render.resolution_y=640;scene.cycles.samples=32
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.blend')
print('Limb refinement saved; approved face and hood untouched.')
