#include "MuseGuardian.h"
#include "Components/SceneComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "ProceduralMeshComponent.h"

// A small, closed 3D accessory. Local +X faces the camera, Y runs across the
// face, and Z runs up. Animation positions its origin at Head-local (34,0,19.2).
void AMuseGuardian::BuildSpyGlasses() {
    SpyGlasses=Joint(TEXT("SpyGlasses"),Rig,FVector::ZeroVector);
    auto Material=[&](FLinearColor Tint) {
        auto* Base=LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_GuardMetal.M_GuardMetal"));
        auto* Mat=UMaterialInstanceDynamic::Create(Base,this);
        Mat->SetVectorParameterValue(TEXT("Tint"),Tint);
        Mat->SetVectorParameterValue(TEXT("Glow"),Tint*.018f);
        Materials.Add(Mat);
        return Mat;
    };
    auto* FrameMaterial=Material(FLinearColor(.012f,.019f,.027f));
    auto* LensMaterial=Material(FLinearColor(.017f,.034f,.058f));
    auto* GlintMaterial=Material(FLinearColor(.075f,.135f,.19f));
    auto* HingeMaterial=Material(FLinearColor(.48f,.31f,.105f));

    // Independent extrusion depth and corner radius keep the lens silhouette
    // smoothly rounded without inflating the shallow frames into toy goggles.
    auto Plate=[&](FName Name,float CentreY,float Width,float Height,float Radius,
                   float CentreX,float Depth,UMaterialInstanceDynamic* Mat) {
        auto* Mesh=NewObject<UProceduralMeshComponent>(this,Name);
        Mesh->SetupAttachment(SpyGlasses);
        Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
        Mesh->SetCastShadow(false);
        Mesh->RegisterComponent();
        TArray<FVector> V,N;
        TArray<int32> Indices;
        constexpr int CornerSteps=16, Count=4*CornerSteps;
        const float Bevel=FMath::Min(.38f,Depth*.3f);
        const float RingX[4]={CentreX-Depth*.5f,CentreX-Depth*.5f+Bevel,
                              CentreX+Depth*.5f-Bevel,CentreX+Depth*.5f};
        for(int Ring=0;Ring<4;++Ring) {
            const float Inset=(Ring==0||Ring==3)?Bevel:0.f;
            const float W=Width*.5f-Inset,H=Height*.5f-Inset,R=Radius-Inset;
            for(int Corner=0;Corner<4;++Corner) for(int K=0;K<CornerSteps;++K) {
                const float A=(Corner*PI*.5f)+(K/float(CornerSteps-1))*PI*.5f;
                const float C=FMath::Cos(A),S=FMath::Sin(A);
                const FVector Radial(0,C,S);
                const float CY=(Corner==0||Corner==3)?W-R:-W+R;
                const float CZ=Corner<2?H-R:-H+R;
                V.Add(FVector(RingX[Ring],CentreY+CY+R*C,CZ+R*S));
                const float Face=Ring==0?-1.f:(Ring==3?1.f:0.f);
                N.Add((Radial+FVector(Face,0,0)).GetSafeNormal());
            }
        }
        for(int Ring=0;Ring<3;++Ring) for(int K=0;K<Count;++K) {
            const int A=Ring*Count+K,B=Ring*Count+(K+1)%Count,C=A+Count,D=B+Count;
            Indices.Append({A,B,C,B,D,C});
        }
        for(int Face=0;Face<2;++Face) {
            const int Base=V.Num(),Ring=Face==0?0:3;
            V.Add(FVector(RingX[Ring],CentreY,0));N.Add(FVector(Face==0?-1:1,0,0));
            for(int K=0;K<Count;++K) {
                const FVector Point=V[Ring*Count+K];
                V.Add(Point);N.Add(FVector(Face==0?-1:1,0,0));
            }
            for(int K=0;K<Count;++K) {
                const int A=Base+1+K,B=Base+1+(K+1)%Count;
                if(Face==0) Indices.Append({Base,B,A});
                else Indices.Append({Base,A,B});
            }
        }
        Mesh->CreateMeshSection(0,V,Indices,N,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
        Mesh->SetMaterial(0,Mat);
        return Mesh;
    };
    auto Rod=[&](FName Name,FVector A,FVector B,float Radius,UMaterialInstanceDynamic* Mat) {
        const FVector Delta=B-A;
        auto* Mesh=Part(Name,SpyGlasses,(A+B)*.5f,FVector(Radius*2,Radius*2,Delta.Size()),FLinearColor::White,TEXT("Cylinder"));
        Mesh->SetRelativeRotation(FQuat::FindBetweenNormals(FVector::UpVector,Delta.GetSafeNormal()));
        Mesh->SetMaterial(0,Mat);Mesh->SetCastShadow(false);
    };
    for(int Side : {-1,1}) {
        const float Y=Side*10.2f;
        Plate(*FString::Printf(TEXT("SpyFrame_%d"),Side),Y,19.6f,10.4f,3.1f,0.f,2.f,FrameMaterial);
        Plate(*FString::Printf(TEXT("SpyLens_%d"),Side),Y,17.0f,7.8f,2.35f,1.15f,.9f,LensMaterial);

        // Restrained, fixed reflections give the smoked lenses depth. They are
        // small mesh strips, not animated emissive streaks or a screen overlay.
        auto Glint=[&](FName Name,FVector2D A,FVector2D B,float Width) {
            auto* Mesh=NewObject<UProceduralMeshComponent>(this,Name);
            Mesh->SetupAttachment(SpyGlasses);Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
            Mesh->SetCastShadow(false);Mesh->RegisterComponent();
            const FVector2D D=(B-A).GetSafeNormal(),Q(-D.Y*Width*.5f,D.X*Width*.5f);
            TArray<FVector> V;
            for(const FVector2D P : {A-Q,B-Q,B+Q,A+Q}) V.Add(FVector(1.612f,Y+P.X,P.Y));
            TArray<FVector> Normals;Normals.Init(FVector::ForwardVector,4);
            Mesh->CreateMeshSection(0,V,TArray<int32>({0,1,2,0,2,3}),Normals,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
            Mesh->SetMaterial(0,GlintMaterial);
        };
        Glint(*FString::Printf(TEXT("SpyLensGlint_%d"),Side),FVector2D(-5.5f,1.2f),FVector2D(-1.7f,2.6f),.30f);
        Glint(*FString::Printf(TEXT("SpyLensSoftGlint_%d"),Side),FVector2D(-4.7f,.65f),FVector2D(-2.6f,1.42f),.14f);

        const FVector Hinge(-.1f,Side*19.8f,1.0f);
        Rod(*FString::Printf(TEXT("SpyTemple_%d"),Side),Hinge,FVector(-12.f,Side*20.8f,.7f),.65f,FrameMaterial);
        Rod(*FString::Printf(TEXT("SpyTempleHook_%d"),Side),FVector(-12.f,Side*20.8f,.7f),FVector(-17.f,Side*19.8f,-1.5f),.66f,FrameMaterial);
        auto* Pin=Part(*FString::Printf(TEXT("SpyHinge_%d"),Side),SpyGlasses,Hinge+FVector(.7f,0,0),FVector(1.2f,1.7f,2.4f),FLinearColor::White);
        Pin->SetMaterial(0,HingeMaterial);Pin->SetCastShadow(false);
    }
    auto* Bridge=Part(TEXT("SpyBridge"),SpyGlasses,FVector(.35f,0,1.2f),FVector(2.1f,4.6f,2.2f),FLinearColor::White);
    Bridge->SetMaterial(0,FrameMaterial);Bridge->SetCastShadow(false);
    SpyGlasses->SetVisibility(false,true);
}
