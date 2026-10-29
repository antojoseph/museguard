"""Run once with UnrealEditor-Cmd -run=pythonscript -script=... ."""
import unreal
asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
def make_material(name, roughness, metallic=0.0):
    path = '/Game/Muse/' + name
    material = unreal.load_asset(path)
    if not material:
        material = asset_tools.create_asset(name, '/Game/Muse', unreal.Material, unreal.MaterialFactoryNew())
        color = unreal.MaterialEditingLibrary.create_material_expression(material, unreal.MaterialExpressionVectorParameter, -400, 0)
        color.set_editor_property('parameter_name', 'Tint')
        color.set_editor_property('default_value', unreal.LinearColor(0.84, 0.79, 0.66, 1))
        unreal.MaterialEditingLibrary.connect_material_property(color, '', unreal.MaterialProperty.MP_BASE_COLOR)
        rough = unreal.MaterialEditingLibrary.create_material_expression(material, unreal.MaterialExpressionConstant, -400, 160)
        rough.set_editor_property('r', roughness)
        unreal.MaterialEditingLibrary.connect_material_property(rough, '', unreal.MaterialProperty.MP_ROUGHNESS)
        metal = unreal.MaterialEditingLibrary.create_material_expression(material, unreal.MaterialExpressionConstant, -400, 240)
        metal.set_editor_property('r', metallic)
        unreal.MaterialEditingLibrary.connect_material_property(metal, '', unreal.MaterialProperty.MP_METALLIC)
        glow = unreal.MaterialEditingLibrary.create_material_expression(material, unreal.MaterialExpressionVectorParameter, -400, 320)
        glow.set_editor_property('parameter_name', 'Glow')
        glow.set_editor_property('default_value', unreal.LinearColor(0, 0, 0, 1))
        unreal.MaterialEditingLibrary.connect_material_property(glow, '', unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    material.set_editor_property('used_with_instanced_static_meshes', True)
    unreal.MaterialEditingLibrary.recompile_material(material)
    unreal.EditorAssetLibrary.save_asset(path)

make_material('M_Guardian', 0.36)
make_material('M_MuseCloth', 0.82)
# Rebuild the plush shader deterministically, including an independent smooth
# pale face panel. Fur coverage comes from the existing vertex mask.
plush_path='/Game/Muse/M_MusePlush'
make_material('M_MusePlush',.88)
mat=unreal.load_asset(plush_path);lib=unreal.MaterialEditingLibrary
lib.delete_all_material_expressions(mat)
def expression(kind,x,y): return lib.create_material_expression(mat,kind,x,y)
tint=expression(unreal.MaterialExpressionVectorParameter,-900,0);tint.set_editor_property('parameter_name','Tint')
face=expression(unreal.MaterialExpressionVectorParameter,-900,-140);face.set_editor_property('parameter_name','FaceTint');face.set_editor_property('default_value',unreal.LinearColor(.93,.73,.65,1))
vertex=expression(unreal.MaterialExpressionVertexColor,-1100,300)
uv=expression(unreal.MaterialExpressionTextureCoordinate,-1100,160)
blend=expression(unreal.MaterialExpressionLinearInterpolate,-620,0)
lib.connect_material_expressions(face,'',blend,'A');lib.connect_material_expressions(tint,'',blend,'B');lib.connect_material_expressions(vertex,'A',blend,'Alpha')
fibers=expression(unreal.MaterialExpressionCustom,-650,200);fibers.set_editor_property('output_type',unreal.CustomMaterialOutputType.CMOT_FLOAT1)
inputs=[]
for name in ['UV','Mask']:
    item=unreal.CustomInput();item.set_editor_property('input_name',name);inputs.append(item)
fibers.set_editor_property('inputs',inputs)
fibers.set_editor_property('code',"float2 p=UV*float2(200,110); p.x+=.24*sin(p.y*1.7); float2 cell=floor(p); float2 f=frac(p); float n=frac(sin(dot(cell,float2(127.1,311.7)))*43758.5453); float fiber=pow(saturate(1-abs(f.x-.5)*2),5)*sin(f.y*3.14159); float aa=saturate(1-max(length(ddx(p)),length(ddy(p)))*.28); return 1-Mask*(.025+aa*(.025+.08*(1-fiber)*n));")
lib.connect_material_expressions(uv,'',fibers,'UV');lib.connect_material_expressions(vertex,'A',fibers,'Mask')
color=expression(unreal.MaterialExpressionMultiply,-320,0);lib.connect_material_expressions(blend,'',color,'A');lib.connect_material_expressions(fibers,'',color,'B');shade=expression(unreal.MaterialExpressionMultiply,-100,0);lib.connect_material_expressions(color,'',shade,'A');lib.connect_material_expressions(vertex,'RGB',shade,'B');lib.connect_material_property(shade,'',unreal.MaterialProperty.MP_BASE_COLOR)
for value,prop,y in [(.88,unreal.MaterialProperty.MP_ROUGHNESS,300),(.22,unreal.MaterialProperty.MP_SPECULAR,380)]:
    node=expression(unreal.MaterialExpressionConstant,-300,y);node.set_editor_property('r',value);lib.connect_material_property(node,'',prop)
glow=expression(unreal.MaterialExpressionVectorParameter,-300,480);glow.set_editor_property('parameter_name','Glow');lib.connect_material_property(glow,'',unreal.MaterialProperty.MP_EMISSIVE_COLOR)
lib.recompile_material(mat);unreal.EditorAssetLibrary.save_asset(plush_path)
fur_path='/Game/Muse/M_MuseFur'
if not unreal.EditorAssetLibrary.does_asset_exist(fur_path):
    make_material('M_MuseFur',.9)
    fur=unreal.load_asset(fur_path);fur.set_editor_property('two_sided',False)
    lib=unreal.MaterialEditingLibrary
    tint=lib.create_material_expression(fur,unreal.MaterialExpressionVectorParameter,-600,0);tint.set_editor_property('parameter_name','Tint')
    color=lib.create_material_expression(fur,unreal.MaterialExpressionVertexColor,-600,150)
    multiply=lib.create_material_expression(fur,unreal.MaterialExpressionMultiply,-300,0)
    lib.connect_material_expressions(tint,'',multiply,'A');lib.connect_material_expressions(color,'RGB',multiply,'B')
    lib.connect_material_property(multiply,'',unreal.MaterialProperty.MP_BASE_COLOR)
    lib.recompile_material(fur);unreal.EditorAssetLibrary.save_asset(fur_path)
# Explicit back faces share the strand's outward shading normal. Two-sided
# normal reversal made the fine fibers sparkle against shaded plush.
fur=unreal.load_asset(fur_path)
fur.set_editor_property('two_sided',False)
unreal.MaterialEditingLibrary.recompile_material(fur)
unreal.EditorAssetLibrary.save_asset(fur_path)
make_material('M_AccessorySatin', 0.62)
make_material('M_GuardMetal', 0.30, 0.45)
shadow_path = '/Game/Muse/M_ContactShadow'
if not unreal.EditorAssetLibrary.does_asset_exist(shadow_path):
    shadow = asset_tools.create_asset('M_ContactShadow', '/Game/Muse', unreal.Material, unreal.MaterialFactoryNew())
    shadow.set_editor_property('blend_mode', unreal.BlendMode.BLEND_TRANSLUCENT)
    shadow.set_editor_property('shading_model', unreal.MaterialShadingModel.MSM_UNLIT)
    vertex = unreal.MaterialEditingLibrary.create_material_expression(shadow, unreal.MaterialExpressionVertexColor, -500, 0)
    strength = unreal.MaterialEditingLibrary.create_material_expression(shadow, unreal.MaterialExpressionScalarParameter, -500, 180)
    strength.set_editor_property('parameter_name', 'Opacity')
    strength.set_editor_property('default_value', 0.18)
    multiply = unreal.MaterialEditingLibrary.create_material_expression(shadow, unreal.MaterialExpressionMultiply, -220, 0)
    unreal.MaterialEditingLibrary.connect_material_expressions(vertex, 'A', multiply, 'A')
    unreal.MaterialEditingLibrary.connect_material_expressions(strength, '', multiply, 'B')
    unreal.MaterialEditingLibrary.connect_material_property(multiply, '', unreal.MaterialProperty.MP_OPACITY)
    black = unreal.MaterialEditingLibrary.create_material_expression(shadow, unreal.MaterialExpressionConstant, -220, 180)
    black.set_editor_property('r', 0.0)
    unreal.MaterialEditingLibrary.connect_material_property(black, '', unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    unreal.MaterialEditingLibrary.recompile_material(shadow)
    unreal.EditorAssetLibrary.save_asset(shadow_path)
if not unreal.EditorAssetLibrary.does_asset_exist('/Game/Maps/MuseStage'):
    subsystem = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
    subsystem.new_level('/Game/Maps/MuseStage')
    subsystem.save_current_level()
unreal.log('MUSE_ASSETS_READY')
