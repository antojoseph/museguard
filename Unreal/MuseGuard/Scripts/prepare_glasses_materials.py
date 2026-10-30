"""Dedicated black metal and clear lens materials; no body material changes."""
import unreal
tools=unreal.AssetToolsHelpers.get_asset_tools()
lib=unreal.MaterialEditingLibrary
for name,glass in [('M_RoundFrame',False),('M_RoundLens',True)]:
    path='/Game/Muse/'+name
    mat=unreal.load_asset(path)
    if not mat:
        mat=tools.create_asset(name,'/Game/Muse',unreal.Material,unreal.MaterialFactoryNew())
    lib.delete_all_material_expressions(mat)
    mat.set_editor_property('two_sided',glass)
    mat.set_editor_property('blend_mode',unreal.BlendMode.BLEND_TRANSLUCENT if glass else unreal.BlendMode.BLEND_OPAQUE)
    if glass:
        mat.set_editor_property('translucency_lighting_mode',unreal.TranslucencyLightingMode.TLM_SURFACE_PER_PIXEL_LIGHTING)
    def constant(value,prop,y):
        e=lib.create_material_expression(mat,unreal.MaterialExpressionConstant,-300,y)
        e.set_editor_property('r',value)
        lib.connect_material_property(e,'',prop)
    color=lib.create_material_expression(mat,unreal.MaterialExpressionConstant3Vector,-300,0)
    color.set_editor_property('constant',unreal.LinearColor(.72,.8,.85) if glass else unreal.LinearColor(.007,.009,.012))
    lib.connect_material_property(color,'',unreal.MaterialProperty.MP_BASE_COLOR)
    constant(.08 if glass else .22,unreal.MaterialProperty.MP_ROUGHNESS,150)
    constant(0 if glass else .65,unreal.MaterialProperty.MP_METALLIC,250)
    constant(.5,unreal.MaterialProperty.MP_SPECULAR,350)
    if glass:
        constant(.02,unreal.MaterialProperty.MP_OPACITY,450)
    lib.recompile_material(mat)
    unreal.EditorAssetLibrary.save_asset(path)
unreal.log('MUSE_ROUND_GLASSES_MATERIALS_READY')
