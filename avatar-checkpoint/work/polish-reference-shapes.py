import bpy,math,numpy as np
from mathutils import Vector
# Lower the shoulder onset while keeping the accepted hand height.
for name in ['Arm_L','Arm_R']:
 ob=bpy.data.objects[name]
 for v in ob.data.vertices:
  z=v.co.z;w=max(0,min(1,(z-.365)/(.965)))
  v.co.z=z-.13*w**1.45
 ob.data.update()
# Slightly fuller hood sides, with the actual face opening left in place.
coat=bpy.data.objects['Coat'];me=coat.data;base=152*176+2;per=(len(me.vertices)-base)//10
# Identify the boundary shared by the body and integral lip.
boundary=set()
for p in me.polygons:
 if any(i>=base for i in p.vertices) and any(i<base for i in p.vertices):
  boundary.update(i for i in p.vertices if i<base)
for v in me.vertices:
 if v.index>=base or v.index in boundary:continue
 x,y,z=v.co;h=max(0,min(1,(z-1.17)/.20));h=h*h*(3-2*h)
 n=2.2 if z>=1.55 else 3.85;r=(abs(x/.425)**n+abs((z-1.55)/.312)**n)**(1/n)
 rweight=max(0,min(1,(r-1)/.32));front=max(0,min(1,(-y-.10)/.18))
 w=h*(1-front*(1-rweight));v.co.x=x*(1+.05*w)
 if z>1.86:v.co.z=z-.012*((z-1.86)/.14)**1.4
me.update()
def lin(v):return v/12.92 if v<=.04045 else((v+.055)/1.055)**2.4
def rgb(h):return tuple(lin(int(h[i:i+2],16)/255) for i in (0,2,4))
skin=next(n for n in bpy.data.materials['FaceMat'].node_tree.nodes if n.type=='BSDF_PRINCIPLED')
skin.inputs['Base Color'].default_value=(*rgb('FFDEA8'),1);skin.inputs['Subsurface Weight'].default_value=.10
skin.inputs['Emission Color'].default_value=(*rgb('F5D6A3'),1);skin.inputs['Emission Strength'].default_value=.025
# Make the eyes read as deep black buttons with one soft catchlight.
eye=next(n for n in bpy.data.materials['EyeMat'].node_tree.nodes if n.type=='BSDF_PRINCIPLED')
eye.inputs['Base Color'].default_value=(*rgb('050504'),1);eye.inputs['Specular IOR Level'].default_value=.075;eye.inputs['Roughness'].default_value=.13
for name in ['Glint_L','Glint_R']:
 ob=bpy.data.objects.get(name)
 if ob:bpy.data.objects.remove(ob,do_unlink=True)
mat=bpy.data.materials.get('SoftEyeHighlight') or bpy.data.materials.new('SoftEyeHighlight');mat.use_nodes=True
bs=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED');bs.inputs['Base Color'].default_value=(1,1,1,1);bs.inputs['Emission Color'].default_value=(1,1,1,1);bs.inputs['Emission Strength'].default_value=.4;bs.inputs['Roughness'].default_value=.5
for side in ['L','R']:
 ob=bpy.data.objects['Eye_'+side];q=ob.rotation_quaternion
 # A tiny elongated upper-right gleam follows the curved eye surface.
 local=Vector((.014,-.019,.021));p=ob.location+q@local
 bpy.ops.mesh.primitive_uv_sphere_add(segments=24,ring_count=16,radius=1,location=p)
 gl=bpy.context.object;gl.name='Glint_'+side;gl.scale=(.0032,.0014,.0053);gl.rotation_mode='QUATERNION';gl.rotation_quaternion=q;gl.data.materials.append(mat)
 for poly in gl.data.polygons:poly.use_smooth=True
# A broad, gentle frontal fill brings the face closer to the warm reference.
light=bpy.data.objects.get('PortraitFill')
if light is None:
 data=bpy.data.lights.new('PortraitFill','AREA');light=bpy.data.objects.new('PortraitFill',data);bpy.context.collection.objects.link(light)
light.location=(.2,-2.1,1.95);light.rotation_euler=(Vector((0,-.25,1.35))-light.location).to_track_quat('-Z','Y').to_euler();light.data.energy=15;light.data.size=1.6;light.data.color=(1,.95,.86)
bpy.context.scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.27
bpy.context.view_layer.update()
print('Lower shoulder onset, fuller hood, warm face and simpler black button eyes refined.')
