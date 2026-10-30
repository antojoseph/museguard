#include "MuseGuardian.h"
#include "Components/SceneComponent.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "ProceduralMeshComponent.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

// Coco Jinjo's glasses fitted by prepare-round-glasses.py. Retain the animated
// attachment and temple grip for the existing put-on, removal and adjustment.
void AMuseGuardian::BuildSpyGlasses() {
    SpyGlasses=Joint(TEXT("SpyGlasses"),Rig,FVector::ZeroVector);
    SpyGlasses->SetVisibility(false,true);
    FString Text;
    TSharedPtr<FJsonObject> File;
    if(!FFileHelper::LoadFileToString(Text,*(FPaths::ProjectContentDir()/TEXT("Muse/RoundGlasses.json"))) ||
       !FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(Text),File) ||
       File->GetIntegerField(TEXT("version"))!=1) {
        UE_LOG(LogTemp,Error,TEXT("Missing or invalid Muse round glasses geometry"));return;
    }
    auto* Frame=LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_RoundFrame.M_RoundFrame"));
    auto* Glass=LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_RoundLens.M_RoundLens"));
    if(!Frame||!Glass) {UE_LOG(LogTemp,Error,TEXT("Missing Muse round glasses materials"));return;}
    for(const auto& Value:File->GetArrayField(TEXT("parts"))) {
        const auto Part=Value->AsObject();
        const auto& V=Part->GetArrayField(TEXT("vertices"));
        const auto& N=Part->GetArrayField(TEXT("normals"));
        const auto& T=Part->GetArrayField(TEXT("indices"));
        if(V.Num()>100000||V.Num()!=N.Num()||T.Num()>600000||T.Num()%3) continue;
        TArray<FVector> Vertices,Normals;TArray<int32> Indices;
        bool Valid=true;
        for(int I=0;I<V.Num();++I) {
            const auto VA=V[I]->AsArray(),NA=N[I]->AsArray();
            if(VA.Num()!=3||NA.Num()!=3) {Valid=false;break;}
            Vertices.Add(FVector(VA[0]->AsNumber(),VA[1]->AsNumber(),VA[2]->AsNumber()));
            Normals.Add(FVector(NA[0]->AsNumber(),NA[1]->AsNumber(),NA[2]->AsNumber()));
            if(Vertices.Last().ContainsNaN()||Normals.Last().ContainsNaN()) {Valid=false;break;}
        }
        for(const auto& I:T) {int32 Index=I->AsNumber();if(Index<0||Index>=V.Num()){Valid=false;break;}Indices.Add(Index);}
        if(!Valid) {UE_LOG(LogTemp,Error,TEXT("Invalid round glasses mesh section"));continue;}
        auto* Mesh=NewObject<UProceduralMeshComponent>(this);
        Mesh->SetupAttachment(SpyGlasses);Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
        Mesh->SetCastShadow(false);Mesh->RegisterComponent();
        Mesh->CreateMeshSection(0,Vertices,Indices,Normals,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
        Mesh->SetMaterial(0,Part->GetStringField(TEXT("material"))==TEXT("glass")?Glass:Frame);
        Mesh->SetVisibility(false);
    }
}
