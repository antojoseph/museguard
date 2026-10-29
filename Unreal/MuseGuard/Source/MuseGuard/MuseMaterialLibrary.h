#pragma once
#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "MuseMaterialLibrary.generated.h"
class UMaterial;
class UMaterialExpression;

/** Editor asset helper: cloth shares the hidden ClearCoat/custom-data input. */
UCLASS()
class MUSEGUARD_API UMuseMaterialLibrary : public UBlueprintFunctionLibrary {
    GENERATED_BODY()
public:
    UFUNCTION(BlueprintCallable, Category="Muse Materials")
    static void SetClothInput(UMaterial* Material, UMaterialExpression* Expression);
};
