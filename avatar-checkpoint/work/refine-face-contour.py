import bpy, math
# Reuse the exact head-surface evaluation from the accepted model.
profile=[(.22,.12,.14),(.25,.28,.25),(.34,.41,.33),(.53,.51,.39),(.82,.54,.40),(1.10,.50,.38),(1.35,.45,.38),(1.62,.445,.375),(1.82,.39,.32),(1.95,.26,.235),(1.995,.07,.07)]
def profile_value(z,k):
    for i in range(len(profile)-1):
        if z<=profile[i+1][0]:break
    p=profile[i];q=profile[i+1];left=profile[max(0,i-1)];right=profile[min(len(profile)-1,i+2)];dz=q[0]-p[0];t=max(0,min(1,(z-p[0])/dz));m0=(q[k]-left[k])/(q[0]-left[0]);m1=(right[k]-p[k])/(right[0]-p[0])
    return max(.001,(2*t**3-3*t*t+1)*p[k]+(t**3-2*t*t+t)*dz*m0+(-2*t**3+3*t*t)*q[k]+(t**3-t*t)*dz*m1)
def head_y(x,z):
    rx=profile_value(z,1);ry=profile_value(z,2);n=2.4+max(0,min(1,(z-1.05)/.3))
    return -ry*max(.001,1-min(.9999,abs(x)/rx)**n)**(1/n)
def point_angle(x,z,a,b):
    xx=x/a;zz=(z-1.48)/b;r=(abs(xx)**3+abs(zz)**3)**(1/3)
    if r<1e-7:return 0,0
    c=math.copysign(abs(xx/r)**1.5,xx);s=math.copysign(abs(zz/r)**1.5,zz)
    return math.atan2(s,c),r
def asymmetric_point(angle,a,b,r=1):
    c=math.cos(angle);s=math.sin(angle)
    # Larger upper corner radius, smaller lower corner radius.
    u=max(0,min(1,(s+.22)/.44));u=u*u*(3-2*u)
    n=3.85+(2.20-3.85)*u
    return a*r*math.copysign(abs(c)**(2/n),c),1.48+b*r*math.copysign(abs(s)**(2/n),s)
face=bpy.data.objects['Face'];coat=bpy.data.objects['Coat']
assert len(face.data.vertices)==2113,'Unexpected face topology; refusing broad deformation'
assert len(coat.data.vertices)==23598,'Unexpected coat topology; refusing broad deformation'
for v in face.data.vertices:
    x,y,z=v.co;angle,r=point_angle(x,z,.36,.305)
    if r<1e-7:continue
    nx,nz=asymmetric_point(angle,.36,.305,r);v.co=(nx,head_y(nx,nz)+.032,nz)
# Blend the same contour into the integral furry lip. Outer coat stays fixed.
base=136*160+2;per_layer=204
for layer in range(1,10):
    t=layer/9;a=.40+(.36-.40)*t;b=.345+(.305-.345)*t;w=t*t*(3-2*t)
    for j in range(per_layer):
        v=coat.data.vertices[base+(layer-1)*per_layer+j];x,y,z=v.co
        angle,r=point_angle(x,z,a,b);tx,tz=asymmetric_point(angle,a,b,r)
        nx=x+(tx-x)*w;nz=z+(tz-z)*w;offset=y-head_y(x,z)
        v.co=(nx,head_y(nx,nz)+offset,nz)
face.data.update();coat.data.update();bpy.context.view_layer.update()
scene=bpy.context.scene;scene.render.resolution_x=640;scene.render.resolution_y=640;scene.cycles.samples=32
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.blend')
print('Upper opening corners softened strongly; lower corners remain squarer. Recess, facial features and limbs preserved.')
