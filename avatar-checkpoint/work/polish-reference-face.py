import bpy,math
from mathutils import Vector
s=bpy.context.scene
# Extend the skin a few millimeters under the coat so differently sampled
# boundary polygons cannot expose hairline cracks at the join.
face=bpy.data.objects['Face'];me=face.data
assert len(me.vertices)==2913
# Only the two outermost radial rings are extended, with a smooth fade inward.
for i,v in enumerate(me.vertices):
 if i==0:continue
 ring=(i-1)//112+1;r=ring/26
 if r<=.85:continue
 amount=.020*((r-.85)/.15)**2
 x,y,z=v.co
 # Interpolate the small overlap on the actual curved skin surface.
 nx=x*(1+amount);nz=1.55+(z-1.55)*(1+amount)
 # Head evaluator shared with the geometry construction.
 profile=[(.22,.12,.14),(.25,.28,.25),(.34,.41,.33),(.53,.51,.39),(.82,.54,.40),(1.10,.50,.38),(1.35,.47,.38),(1.62,.475,.375),(1.82,.415,.32),(1.95,.28,.235),(1.995,.075,.07)]
 def pv(z,k):
  for j in range(len(profile)-1):
   if z<=profile[j+1][0]:break
  p=profile[j];q=profile[j+1];l=profile[max(0,j-1)];r=profile[min(len(profile)-1,j+2)];dt=q[0]-p[0];t=max(0,min(1,(z-p[0])/dt));m0=(q[k]-l[k])/(q[0]-l[0]);m1=(r[k]-p[k])/(r[0]-p[0])
  return max(.001,(2*t**3-3*t*t+1)*p[k]+(t**3-2*t*t+t)*dt*m0+(-2*t**3+3*t*t)*q[k]+(t**3-t*t)*dt*m1)
 n=2.4+max(0,min(1,(nz-1.05)/.3));hy=-pv(nz,2)*max(.001,1-min(.9999,abs(nx)/pv(nz,1))**n)**(1/n)
 v.co=(nx,hy+.022,nz)
me.update()
face['SkinUnderlap']=.02
# The white background is raised above diffuse white for AgX's highlight rolloff.
nt=s.compositing_node_group;over=next(n for n in nt.nodes if n.bl_idname=='CompositorNodeAlphaOver');over.inputs['Background'].default_value=(12,12,12,1)
s.render.resolution_x=1080;s.render.resolution_y=1200;s.cycles.samples=128
s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/reference-polish-preview.png'
bpy.context.view_layer.update()
bpy.ops.render.render(write_still=True)
print('Face join closed with buried overlap; final cream plush lighting preview rendered.')
