#include "MuseMaterialLibrary.h"
#include "Materials/Material.h"
#include "Materials/MaterialExpression.h"

void UMuseMaterialLibrary::SetClothInput(UMaterial* Material, UMaterialExpression* Expression) {
#if WITH_EDITOR
    if(Material) {
        // MP_CustomData0 is intentionally hidden from Unreal's Python enum.
        Material->GetEditorOnlyData()->ClearCoat.Expression=Expression;
        Material->GetEditorOnlyData()->ClearCoat.OutputIndex=0;
    }
#endif
}
