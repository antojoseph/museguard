#include "MuseGuardian.h"
#include "Async/ParallelFor.h"
#include "Math/PerspectiveMatrix.h"
#include <cstdio>
#include "Components/StaticMeshComponent.h"
#include "ProceduralMeshComponent.h"
#include "Serialization/MemoryReader.h"
#include "Components/SceneCaptureComponent2D.h"
#include "Components/DirectionalLightComponent.h"
#include "Components/PointLightComponent.h"
#include "Engine/TextureRenderTarget2D.h"
#include "Engine/World.h"
#include "Engine/Engine.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformMisc.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "TextureResource.h"

AMuseGuardGameMode::AMuseGuardGameMode() { DefaultPawnClass = nullptr; }
void AMuseGuardGameMode::StartPlay() {
    Super::StartPlay();
    GetWorld()->SpawnActor<AMuseGuardian>();
}
AMuseGuardian::AMuseGuardian() {
    PrimaryActorTick.bCanEverTick = true;
    RootComponent = CreateDefaultSubobject<USceneComponent>(TEXT("Scene"));
}
USceneComponent* AMuseGuardian::Joint(FName Name, USceneComponent* Parent, FVector Position) {
    auto* Node = NewObject<USceneComponent>(this, Name);
    Node->SetupAttachment(Parent);
    Node->SetRelativeLocation(Position);
    Node->RegisterComponent();
    return Node;
}
UStaticMeshComponent* AMuseGuardian::Part(FName Name, USceneComponent* Parent, FVector Position, FVector Size, FLinearColor Tint, FString Shape, bool Glow) {
    auto* Mesh = NewObject<UStaticMeshComponent>(this, Name);
    Mesh->SetupAttachment(Parent);
    Mesh->SetStaticMesh(LoadObject<UStaticMesh>(nullptr, *(TEXT("/Engine/BasicShapes/") + Shape + TEXT(".") + Shape)));
    Mesh->SetRelativeLocation(Position);
    Mesh->SetRelativeScale3D(Size / 100.f);
    Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    auto* Base = LoadObject<UMaterialInterface>(nullptr, TEXT("/Game/Muse/M_AccessorySatin.M_AccessorySatin"));
    auto* Mat = UMaterialInstanceDynamic::Create(Base, this);
    if (Mat) {
        Mat->SetVectorParameterValue(TEXT("Tint"), Tint);
        Mat->SetVectorParameterValue(TEXT("Glow"), Glow ? Tint * .45f : Tint * .06f);
        Mesh->SetMaterial(0, Mat);
        Materials.Add(Mat);
    }
    Mesh->RegisterComponent();
    return Mesh;
}
namespace {
    void Damped(float& Value, float& Velocity, float TargetValue, float Frequency, float Dt) {
        const float Offset=Value-TargetValue, J=Velocity+Frequency*Offset;
        const float Decay=FMath::Exp(-Frequency*Dt);
        Value=TargetValue+(Offset+J*Dt)*Decay;
        Velocity=(Velocity-Frequency*J*Dt)*Decay;
    }
    const FQuat& RestingHeadRotation() { static const FQuat Q=FRotator(0,-90,-18).Quaternion();return Q; }
    double RestingFoldDepth(const FVector& R) {
        return 7*FMath::Exp(-.5*FMath::Square(R.Y/4.5))
            *FMath::SmoothStep(10.f,30.f,float(-R.X))
            *FMath::Exp(-.5*FMath::Square((R.Z-30.)/15.))
            *FMath::SmoothStep(14.f,24.f,float(R.Z));
    }
    FVector RestingPoint(const FVector& R,int Group,const FVector& TailCentre) {
        // A bed-space shape target preserves rounded plush volumes. Rotating
        // the upright rig alone made its standing belly depth a tall hump.
        FVector Torso(-45.+.95*R.Z+RestingFoldDepth(R),1.03*R.Y,47.8-.58*R.X);
        const FVector Head=FVector(43,-12,52)+RestingHeadRotation().RotateVector(R-FVector(0,0,96));
        if(Group==3) return Head;
        if(Group==4) {
            const FVector D=R-TailCentre;
            return FVector(-45.+.95*TailCentre.Z+RestingFoldDepth(TailCentre),1.03*TailCentre.Y,47.8-.58*TailCentre.X)+FVector(D.Z,D.Y,-D.X);
        }
        if(Group==1||Group==2) {
            const float Side=Group==1?-1.f:1.f;
            const FVector Pivot(0,Side*31.16,65.6);
            const FVector Axis=FVector(4.92,Side*8.2,-28.7).GetSafeNormal();
            const FVector Aim=Group==1?FVector(1,-.12,-.10):FVector(.85,-.5,-.10);
            const FQuat Rotation=FQuat::FindBetweenNormals(Axis,Aim.GetSafeNormal());
            const FVector D=R-Pivot;
            const double Along=FVector::DotProduct(D,Axis);
            const FVector Arm=FVector(18,Side*29,43)+Rotation.RotateVector((D-Axis*Along)*.92+Axis*Along*.72);
            return FMath::Lerp(Arm,Torso,double(FMath::SmoothStep(65.f,76.f,float(R.Z))));
        }
        const float Side=2*FMath::SmoothStep(-8.f,8.f,float(R.Y))-1;
        FVector Foot(-39.+.75*(R.Z-10),Side*24.+(R.Y-Side*16.4),35.3-.45*R.X);
        const double SoleRadius=FMath::Square(R.X/20.)+FMath::Square((R.Y-Side*16.4)/10.);
        Foot.X-=3*FMath::Pow(FMath::Max(0.,1-SoleRadius),.6)*(1-FMath::SmoothStep(0.f,7.f,float(R.Z)));
        Torso=FMath::Lerp(Foot,Torso,double(FMath::SmoothStep(16.f,30.f,float(R.Z))));
        return FMath::Lerp(Torso,Head,double(FMath::SmoothStep(70.f,90.f,float(R.Z))));
    }
    // Rest pivots match scripts/prepare-muse-mesh.py, in Unreal centimeters.
    const FVector Pivots[12] = {FVector::ZeroVector, FVector(0,0,78), FVector(0,-31.16,65.6), FVector(0,31.16,65.6), FVector(0,-16.4,22), FVector(0,16.4,22), FVector(4.92,-39.36,36.9), FVector(4.92,39.36,36.9), FVector(0,-16.4,11), FVector(0,16.4,11), FVector(0,-16.4,3), FVector(0,16.4,3)};
}
void AMuseGuardian::BuildCharacter() {
    TravelRoot = Joint(TEXT("WorldTravel"), RootComponent, FVector::ZeroVector);
    Rig = Joint(TEXT("CharacterRoot"), TravelRoot, FVector::ZeroVector);
    Head = Joint(TEXT("HeadSocket"), Rig, Pivots[1]);
    for(int B=0;B<12;++B) { BoneRotations[B]=FQuat::Identity; BoneOffsets[B]=FVector::ZeroVector; }
    CharacterMesh = NewObject<UProceduralMeshComponent>(this, TEXT("OriginalMuseJolly"));
    CharacterMesh->SetupAttachment(Rig);
    CharacterMesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    // Soft studio shading avoids shadow-map terminator facets on the plush.
    CharacterMesh->SetCastShadow(false);
    CharacterMesh->RegisterComponent();
    TArray<uint8> Data;
    if(!FFileHelper::LoadFileToArray(Data, *(FPaths::ProjectContentDir()/TEXT("Muse/Jolly.musemesh")))) {
        UE_LOG(LogTemp, Error, TEXT("Missing credited Muse mesh: Content/Muse/Jolly.musemesh")); return;
    }
    FMemoryReader Reader(Data);
    uint32 Magic=0, Version=0, Count=0;
    Reader << Magic << Version << Count;
    if(Magic!=0x4D55534B || Version!=3 || Count!=3) { UE_LOG(LogTemp,Error,TEXT("Invalid Muse mesh header")); return; }
    for(uint32 S=0;S<Count;++S) {
        if(Reader.TotalSize()-Reader.Tell()<20) return;
        uint32 VertexCount=0, IndexCount=0; float R=0,G=0,B=0;
        Reader << VertexCount << IndexCount << R << G << B;
        if(VertexCount==0 || VertexCount>100000 || IndexCount>600000 || IndexCount%3!=0 ||
           Reader.TotalSize()-Reader.Tell()<int64(VertexCount)*72+int64(IndexCount)*4) {
            UE_LOG(LogTemp,Error,TEXT("Invalid Muse mesh section %u v=%u i=%u remaining=%lld"),S,VertexCount,IndexCount,Reader.TotalSize()-Reader.Tell()); return;
        }
        FMuseSkinSection Section;
        Section.Rest.SetNum(VertexCount); Section.Positions.SetNum(VertexCount); Section.Normals.SetNum(VertexCount);
        Section.UVs.SetNum(VertexCount); Section.Colors.SetNum(VertexCount);
        for(uint32 V=0;V<VertexCount;++V) {
            float Values[18]; Reader.Serialize(Values,sizeof(Values));
            auto& Vertex=Section.Rest[V];
            Vertex.Position=FVector(Values[0],Values[1],Values[2]); Vertex.Normal=FVector(Values[3],Values[4],Values[5]);
            float Total=0;
            for(int W=0;W<12;++W) { Vertex.Weights[W]=Values[6+W]; Total+=Values[6+W]; }
            if(Vertex.Position.ContainsNaN() || Vertex.Normal.ContainsNaN() || !FMath::IsNearlyEqual(Total,1.f,.001f)) return;
            Section.Positions[V]=Vertex.Position; Section.Normals[V]=Vertex.Normal;
            const FVector P=Vertex.Position;
            Section.UVs[V]=FVector2D(.5+FMath::Atan2(P.Y,P.X)/(2*PI),P.Z/124.);
            const float Face=FMath::Pow(FMath::Abs(P.Y)/23.f,4.f)+FMath::Pow(FMath::Abs(P.Z-97.f)/17.f,4.f);
            const float Plush=P.X>20?FMath::SmoothStep(.75f,1.15f,Face):1.f;
            Section.Colors[V]=FColor(255,255,255,uint8(Plush*255));
        }
        Section.Indices.SetNum(IndexCount); Reader.Serialize(Section.Indices.GetData(),IndexCount*4);
        for(int32 Index:Section.Indices) if(Index<0 || Index>=int32(VertexCount)) return;
        if(S==0) {
            TArray<int32> Parent;Parent.SetNum(VertexCount);
            for(uint32 V=0;V<VertexCount;++V) Parent[V]=V;
            auto Find=[&Parent](int32 V) { while(Parent[V]!=V) { Parent[V]=Parent[Parent[V]];V=Parent[V]; } return V; };
            for(int I=0;I<Section.Indices.Num();I+=3) {
                const int A=Find(Section.Indices[I]);
                Parent[Find(Section.Indices[I+1])]=A;Parent[Find(Section.Indices[I+2])]=A;
            }
            TMap<int32,int32> Counts;int32 Main=0,Max=0;
            for(uint32 V=0;V<VertexCount;++V) { const int Root=Find(V);const int N=++Counts.FindOrAdd(Root);if(N>Max) {Max=N;Main=Root;} }
            FVector TailSum=FVector::ZeroVector;int TailCount=0;
            for(uint32 V=0;V<VertexCount;++V) if(Find(V)!=Main) {
                auto& TailVertex=Section.Rest[V];
                if(Counts[Find(V)]<3000&&TailVertex.Position.X< -35) { TailVertex.SleepGroup=4;TailSum+=TailVertex.Position;++TailCount; }
                else TailVertex.SleepGroup=TailVertex.Position.Y<0?1:2;
            }
            if(TailCount) SleepTailCentre=TailSum/TailCount;
            // Dense plush occludes soft fill inside the sculpted fold. The
            // transparent studio has no screen-space AO, so carry that local
            // occlusion with the surface instead of painting a hard seam.
            for(uint32 V=0;V<VertexCount;++V) if(Section.Rest[V].SleepGroup==0) {
                const FVector P=Section.Rest[V].Position;
                const float Fold=FMath::Exp(-.5f*FMath::Square(float(P.Y/3.5)))
                    *FMath::SmoothStep(18.f,32.f,float(-P.X))
                    *FMath::SmoothStep(18.f,26.f,float(P.Z))
                    *(1-FMath::SmoothStep(50.f,62.f,float(P.Z)));
                const uint8 Shade=uint8(255*(1-.24f*Fold));
                Section.Colors[V].R=Section.Colors[V].G=Section.Colors[V].B=Shade;
            }

        }
        if(S==0) {
            Section.Neighbors.SetNum(VertexCount); Section.SmoothMask.SetNumZeroed(VertexCount); Section.Smoothed.SetNum(VertexCount);
            for(uint32 V=0;V<VertexCount;++V) {
                const auto& W=Section.Rest[V].Weights;
                const float Arms=W[2]+W[3]+W[6]+W[7];
                const float Legs=W[4]+W[5]+W[8]+W[9]+W[10]+W[11];
                const float Mask=FMath::Max(4.f*W[1]*(1-W[1]),FMath::Max(FMath::Max(4.f*Arms*(1-Arms),4.f*(W[2]*W[6]+W[3]*W[7])),FMath::Max(4.f*Legs*(1-Legs),4.f*(W[4]*W[8]+W[5]*W[9]+W[8]*W[10]+W[9]*W[11]))));
                if(Mask>.015f) { Section.SmoothVertices.Add(V); Section.SmoothMask[V]=Mask; }
            }
            for(int I=0;I<Section.Indices.Num();I+=3) for(int Corner=0;Corner<3;++Corner) {
                const int V=Section.Indices[I+Corner];
                if(Section.SmoothMask[V]>.015f) {
                    Section.Neighbors[V].AddUnique(Section.Indices[I+(Corner+1)%3]);
                    Section.Neighbors[V].AddUnique(Section.Indices[I+(Corner+2)%3]);
                }
            }
        }
        CharacterMesh->CreateMeshSection(S,Section.Positions,Section.Indices,Section.Normals,Section.UVs,Section.Colors,TArray<FProcMeshTangent>(),false);
        auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,S==0?TEXT("/Game/Muse/M_MusePlush.M_MusePlush"):TEXT("/Game/Muse/M_Guardian.M_Guardian")),this);
        Mat->SetVectorParameterValue(TEXT("Tint"),S==0?FLinearColor(.76,.43,.36):FLinearColor(R,G,B));
        if(S==0) Mat->SetVectorParameterValue(TEXT("FaceTint"),FLinearColor(.93,.73,.65));
        Mat->SetVectorParameterValue(TEXT("Glow"),(S==0?FLinearColor(.76,.43,.36):FLinearColor(R,G,B))*(S==0?.16f:.035f));
        CharacterMesh->SetMaterial(S,Mat); Materials.Add(Mat);
        Skin.Add(MoveTemp(Section));
    }
    UE_LOG(LogTemp,Display,TEXT("MUSE_IMPORTED_MESH_READY source=MadDog2125 sections=%d rig=12-bone"),Skin.Num());
}
void AMuseGuardian::AnimateMesh(float Blink, float Talk) {
    const float RestAmount=FMath::SmoothStep(.44f,.96f,SleepAmount);
    const FTransform SleepRoot=Rig->GetRelativeTransform();
    FQuat Dual[12];
    for(int B=0;B<12;++B) {
        const FVector Translation=Pivots[B]-BoneRotations[B].RotateVector(Pivots[B])+BoneOffsets[B];
        Dual[B]=(FQuat(Translation.X,Translation.Y,Translation.Z,0)*BoneRotations[B])*.5;
    }
    for(int S=0;S<Skin.Num();++S) {
        auto& Section=Skin[S];
        for(int V=0;V<Section.Rest.Num();++V) {
            const auto& Rest=Section.Rest[V]; FVector P=Rest.Position, N=Rest.Normal;
            // Continuous local plush motion, fading out before the hips,
            // shoulders and belly. Fur follows this same corrected surface.
            if(S==0) {
                const float Mask=Rest.Weights[0]*FMath::SmoothStep(20.f,35.f,float(-P.X))
                    *FMath::SmoothStep(18.f,28.f,float(P.Z))
                    *FMath::Exp(-.5f*FMath::Square(float((P.Z-40)/16)))
                    *FMath::Exp(-.5f*FMath::Square(float(P.Y/27)));
                P+=RumpOffset*Mask;
            }
            // Compress the original raised eyes and their surrounding surface.
            // Moving neighboring skin closes the eyelid without exposing a hole.
            if(S==1 && P.X>20 && P.Z>91 && P.Z<101) {
                const float DY=(FMath::Abs(P.Y)-10.25f)/4.2f, DZ=(P.Z-95.858f)/4.7f;
                const float Amount=Blink*(1-FMath::SmoothStep(.45f,1.f,DY*DY+DZ*DZ));
                P.Z=95.858f+(P.Z-95.858f)*(1-.93f*Amount);
                N.Z/=FMath::Max(.07f,1-.93f*Amount); N.Normalize();
            }
            if(S==2) P.Z=91.8f+(P.Z-91.8f)*(1+Talk*.25f);
            // Dual-quaternion blending keeps the shoulder volume through a
            // large bend; linear blending collapses it into a pinched crease.
            FQuat Real(0,0,0,0), BlendDual(0,0,0,0);
            for(int B=0;B<12;++B) if(Rest.Weights[B]>.00001f) {
                const double Sign=BoneRotations[B].W<0?-1.:1.;
                Real=Real+BoneRotations[B]*(Rest.Weights[B]*Sign);
                BlendDual=BlendDual+Dual[B]*(Rest.Weights[B]*Sign);
            }
            const double InvLength=1./FMath::Sqrt(Real.SizeSquared());
            Real=Real*InvLength; BlendDual=BlendDual*InvLength;
            const FQuat Translation=(BlendDual*Real.Inverse())*2.;
            Section.Positions[V]=Real.RotateVector(P)+FVector(Translation.X,Translation.Y,Translation.Z);
            Section.Normals[V]=Real.RotateVector(N).GetSafeNormal();
            if(RestAmount>.001f) {
                const int Group=S==0?Rest.SleepGroup:3;
                FVector Resting=RestingPoint(P,Group,SleepTailCentre);
                if(Group==0) Resting.Z+=.5*FMath::Sin(Time*1.25f)*Rest.Weights[0]
                    *(1-FMath::SmoothStep(-10.f,20.f,float(P.X)));
                Section.Positions[V]=FMath::Lerp(Section.Positions[V],SleepRoot.InverseTransformPosition(Resting),double(RestAmount));
                if(S!=0) Section.Normals[V]=FMath::Lerp(Section.Normals[V],SleepRoot.InverseTransformVectorNoScale(RestingHeadRotation().RotateVector(N)),double(RestAmount)).GetSafeNormal();
            }

        }
        if(S==0) {
            // Corrective smoothing softens the inside of bent joints while
            // leaving the original hand, torso and face silhouettes intact.
            for(int Pass=0;Pass<12 && JointCorrection>.01f;++Pass) {
                for(int V:Section.SmoothVertices) {
                    FVector Average=FVector::ZeroVector;
                    for(int Neighbor:Section.Neighbors[V]) Average+=Section.Positions[Neighbor];
                    Average/=FMath::Max(1,Section.Neighbors[V].Num());
                    Section.Smoothed[V]=FMath::Lerp(Section.Positions[V],Average,Section.SmoothMask[V]*JointCorrection*.6f);
                }
                for(int V:Section.SmoothVertices) Section.Positions[V]=Section.Smoothed[V];
            }
            // The pillow-facing head can pull nearby neck skin through the
            // mattress. Apply soft contact after skinning and joint smoothing,
            // then recompute normals and attach fur to the corrected surface.
            const float MattressContact=FMath::SmoothStep(.44f,.96f,SleepAmount);
            if(MattressContact>.001f) for(int V=0;V<Section.Rest.Num();++V) {
                const FVector R=Section.Rest[V].Position;
                const float Weight=MattressContact*FMath::SmoothStep(20.f,30.f,float(R.Z))
                    *(1-FMath::SmoothStep(75.f,85.f,float(R.Z)));
                auto& P=Section.Positions[V];
                if(P.X>26.5) P.X=FMath::Lerp(P.X,26.5+.5*FMath::Tanh((P.X-26.5)/.5),double(Weight));
            }
            // Recompute the body/joint normals after bending. Rotating rest
            // normals alone leaves triangular highlights across blended caps.
            for(auto& N:Section.Normals) N=FVector::ZeroVector;
            for(int I=0;I<Section.Indices.Num();I+=3) {
                const int A=Section.Indices[I], B=Section.Indices[I+1], C=Section.Indices[I+2];
                const FVector N=FVector::CrossProduct(Section.Positions[C]-Section.Positions[A],Section.Positions[B]-Section.Positions[A]);
                Section.Normals[A]+=N; Section.Normals[B]+=N; Section.Normals[C]+=N;
            }
            for(auto& N:Section.Normals) N.Normalize();
        }
        CharacterMesh->UpdateMeshSection(S,Section.Positions,Section.Normals,Section.UVs,Section.Colors,TArray<FProcMeshTangent>());
    }
}
void AMuseGuardian::BuildFur() {
    if(Skin.IsEmpty()) return;
    auto& Body=Skin[0];
    TArray<double> Areas;double Total=0;
    for(int I=0;I<Body.Indices.Num();I+=3) {
        const FVector A=Body.Positions[Body.Indices[I]],B=Body.Positions[Body.Indices[I+1]],C=Body.Positions[Body.Indices[I+2]];
        Total+=FVector::CrossProduct(B-A,C-A).Length()*.5;Areas.Add(Total);
    }
    FRandomStream Random(1729);
    for(int Attempt=0;Attempt<320000 && FurRoots.Num()<32000;++Attempt) {
        const double Pick=Random.FRand()*Total;int Lo=0,Hi=Areas.Num()-1;
        while(Lo<Hi) { const int Mid=(Lo+Hi)/2;if(Areas[Mid]<Pick) Lo=Mid+1;else Hi=Mid; }
        const int A=Body.Indices[Lo*3],B=Body.Indices[Lo*3+1],C=Body.Indices[Lo*3+2];
        const float U=FMath::Sqrt(Random.FRand()),V=Random.FRand();
        const FVector Bary(1-U,U*(1-V),U*V);
        const FVector P=Body.Positions[A]*Bary.X+Body.Positions[B]*Bary.Y+Body.Positions[C]*Bary.Z;
        const float Face=FMath::Pow(FMath::Abs(P.Y)/24.f,4.f)+FMath::Pow(FMath::Abs(P.Z-97.f)/18.f,4.f);
        if(P.X>17 && Face<1.2f) continue;
        const FVector N=(Body.Normals[A]*Bary.X+Body.Normals[B]*Bary.Y+Body.Normals[C]*Bary.Z).GetSafeNormal();
        const FVector T=(Body.Positions[B]-Body.Positions[A]).GetSafeNormal();
        const FVector Side=FVector::CrossProduct(N,T).GetSafeNormal();
        const FVector Down=(FVector(0,0,-1)+N*N.Z).GetSafeNormal();
        const float Border=P.X>17?FMath::SmoothStep(1.2f,1.8f,Face):1.f;
        const float Length=Random.FRandRange(.9f,1.5f)*FMath::Lerp(.42f,1.f,Border)*FMath::Lerp(.38f,1.f,FMath::SmoothStep(0.f,6.f,float(P.Z)));
        FurRoots.Add({A,B,C,Bary,Length,Random.FRandRange(.075f,.12f),Random.FRandRange(0,PI),
            FVector2D(FVector::DotProduct(Down,T),FVector::DotProduct(Down,Side)),Random.FRandRange(.35f,.65f)});
        const float Occlusion=(Body.Colors[A].R*Bary.X+Body.Colors[B].R*Bary.Y+Body.Colors[C].R*Bary.Z)/255.f;
        const float Tone=Random.FRandRange(.98f,1.f)*Occlusion;
        for(int K=0;K<2;++K) {
            // Darker roots and pearl-colored tips provide soft pile depth.
            for(float Level : {.87f,.87f,.96f,.96f,1.f}) {
                const uint8 Shade=uint8(255*Tone*Level);
                FurColors.Add(FColor(Shade,Shade,Shade));
            }
            const int Base=(FurRoots.Num()-1)*10+K*5;
            for(const FIntVector Triangle : {FIntVector(0,1,2),FIntVector(1,3,2),FIntVector(2,3,4)})
                FurIndices.Append({Base+Triangle.X,Base+Triangle.Y,Base+Triangle.Z,
                    Base+Triangle.Z,Base+Triangle.Y,Base+Triangle.X});
        }
    }
    FurPositions.SetNum(FurRoots.Num()*10);FurNormals.SetNum(FurRoots.Num()*10);
    FurMesh=NewObject<UProceduralMeshComponent>(this,TEXT("ShortPlushFibers"));
    FurMesh->SetupAttachment(Rig);FurMesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);FurMesh->SetCastShadow(false);FurMesh->RegisterComponent();
    UpdateFur();
    FurMesh->CreateMeshSection(0,FurPositions,FurIndices,FurNormals,TArray<FVector2D>(),FurColors,TArray<FProcMeshTangent>(),false);
    auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_MuseFur.M_MuseFur")),this);
    Mat->SetVectorParameterValue(TEXT("Tint"),FLinearColor(.80,.48,.40));Mat->SetVectorParameterValue(TEXT("Glow"),FLinearColor(.80,.48,.40)*.07f);
    FurMesh->SetMaterial(0,Mat);Materials.Add(Mat);
}
void AMuseGuardian::UpdateFur() {
    if(FurRoots.IsEmpty()) return;
    auto& Body=Skin[0];
    ParallelFor(FurRoots.Num(),[&](int I) {
        const auto& F=FurRoots[I];
        const FVector N=(Body.Normals[F.A]*F.Bary.X+Body.Normals[F.B]*F.Bary.Y+Body.Normals[F.C]*F.Bary.Z).GetSafeNormal();
        const FVector P=Body.Positions[F.A]*F.Bary.X+Body.Positions[F.B]*F.Bary.Y+Body.Positions[F.C]*F.Bary.Z+N*.025;
        const FVector Edge=(Body.Positions[F.B]-Body.Positions[F.A]).GetSafeNormal();
        const FVector T=(Edge-N*FVector::DotProduct(Edge,N)).GetSafeNormal();
        const FVector B=FVector::CrossProduct(N,T).GetSafeNormal();
        const FVector Comb=(T*F.Groom.X+B*F.Groom.Y).GetSafeNormal();
        const FVector Middle=P+N*(F.Length*.57)+Comb*(F.Length*F.Bend*.20);
        const FVector Tip=P+N*(F.Length*.92)+Comb*(F.Length*F.Bend);
        for(int Cross=0;Cross<2;++Cross) {
            const float Angle=F.Angle+Cross*PI*.5;
            const FVector W=(T*FMath::Cos(Angle)+B*FMath::Sin(Angle))*F.Width;
            const int J=I*10+Cross*5;
            FurPositions[J]=P-W;FurPositions[J+1]=P+W;
            FurPositions[J+2]=Middle-W*.62;FurPositions[J+3]=Middle+W*.62;FurPositions[J+4]=Tip;
            FurNormals[J]=FurNormals[J+1]=N;
            FurNormals[J+2]=FurNormals[J+3]=(N-Comb*.12).GetSafeNormal();
            FurNormals[J+4]=(N-Comb*.25).GetSafeNormal();
        }
    });
    if(FurMesh && FurMesh->GetProcMeshSection(0)) FurMesh->UpdateMeshSection(0,FurPositions,FurNormals,TArray<FVector2D>(),FurColors,TArray<FProcMeshTangent>());
}
void AMuseGuardian::BuildAccessories() {
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *(FPaths::ProjectConfigDir()/TEXT("MuseAccessories.json")))) return;
    TSharedPtr<FJsonObject> Json;
    if(!FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(Text),Json)) return;
    TSharedPtr<FJsonObject> Geometry;
    FString MeshText;
    if(FFileHelper::LoadFileToString(MeshText,*(FPaths::ProjectContentDir()/TEXT("Muse/GuardAccessories.json")))) {
        TSharedPtr<FJsonObject> File;
        if(FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(MeshText),File)&&File->GetIntegerField(TEXT("version"))==1)
            Geometry=File->GetObjectField(TEXT("meshes"));
    }
    for (auto& Item : Json->GetArrayField(TEXT("accessories"))) {
        auto Object=Item->AsObject();
        FString Name=Object->GetStringField(TEXT("id"));
        for(auto& PartValue : Object->GetArrayField(TEXT("parts"))) {
            auto P=PartValue->AsObject();
            auto Vector=[&](const TCHAR* Key){auto A=P->GetArrayField(Key); return FVector(A[0]->AsNumber(),A[1]->AsNumber(),A[2]->AsNumber());};
            auto C=P->GetArrayField(TEXT("color"));
            auto* Socket=P->GetStringField(TEXT("socket"))==TEXT("head")?Head:Rig;
            USceneComponent* Mesh=nullptr;
            if(P->HasField(TEXT("geometry"))) {
                const FString MeshName=P->GetStringField(TEXT("geometry"));
                if(!Geometry||!Geometry->HasField(MeshName)) { UE_LOG(LogTemp,Error,TEXT("Missing accessory geometry %s"),*MeshName); continue; }
                auto G=Geometry->GetObjectField(MeshName);
                const auto& V=G->GetArrayField(TEXT("vertices")); const auto& N=G->GetArrayField(TEXT("normals"));
                const auto& T=G->GetArrayField(TEXT("indices"));
                if(V.Num()>100000||V.Num()!=N.Num()||T.Num()>600000||T.Num()%3) continue;
                TArray<FVector> Vertices,Normals;TArray<int32> Indices;
                bool Valid=true;
                for(int I=0;I<V.Num();++I) {
                    auto VA=V[I]->AsArray(),NA=N[I]->AsArray();
                    if(VA.Num()!=3||NA.Num()!=3) { Valid=false;break; }
                    Vertices.Add(FVector(VA[0]->AsNumber(),VA[1]->AsNumber(),VA[2]->AsNumber()));
                    Normals.Add(FVector(NA[0]->AsNumber(),NA[1]->AsNumber(),NA[2]->AsNumber()));
                    if(Vertices.Last().ContainsNaN()||Normals.Last().ContainsNaN()) { Valid=false;break; }
                }
                for(auto& I:T) { int32 Index=I->AsNumber(); if(Index<0||Index>=V.Num()) {Valid=false;break;} Indices.Add(Index); }
                if(!Valid) continue;
                auto* Custom=NewObject<UProceduralMeshComponent>(this);
                Custom->SetupAttachment(Socket);Custom->SetRelativeLocation(Vector(TEXT("position")));Custom->SetRelativeScale3D(Vector(TEXT("size")));
                Custom->SetCollisionEnabled(ECollisionEnabled::NoCollision);Custom->RegisterComponent();
                Custom->CreateMeshSection(0,Vertices,Indices,Normals,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
                const bool Metal=P->GetStringField(TEXT("material"))==TEXT("metal");
                auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,Metal?TEXT("/Game/Muse/M_GuardMetal.M_GuardMetal"):TEXT("/Game/Muse/M_AccessorySatin.M_AccessorySatin")),this);
                const FLinearColor Tint(C[0]->AsNumber(),C[1]->AsNumber(),C[2]->AsNumber());
                Mat->SetVectorParameterValue(TEXT("Tint"),Tint);Mat->SetVectorParameterValue(TEXT("Glow"),Tint*(Metal?.07f:.035f));
                Custom->SetMaterial(0,Mat);Materials.Add(Mat);Mesh=Custom;
            } else {
                Mesh=Part(NAME_None,Socket,Vector(TEXT("position")),Vector(TEXT("size")),FLinearColor(C[0]->AsNumber(),C[1]->AsNumber(),C[2]->AsNumber()),P->GetStringField(TEXT("shape")));
            }
            if(P->HasField(TEXT("rotation"))) {auto V=Vector(TEXT("rotation"));Mesh->SetRelativeRotation(FRotator(V.X,V.Y,V.Z));}
            Mesh->SetVisibility(Name==Accessory);
            AccessoryRoots.Add(Mesh);AccessoryNames.Add(Name);
        }
    }
}
void AMuseGuardian::BuildContactShadow() {
    ContactShadow=NewObject<UProceduralMeshComponent>(this,TEXT("GroundContactShadow"));
    ContactShadow->SetupAttachment(RootComponent); ContactShadow->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    ContactShadow->SetCastShadow(false); ContactShadow->RegisterComponent();
    TArray<FVector> Vertices,Normals; TArray<FColor> Colors; TArray<int32> Indices;
    Vertices.Add(FVector::ZeroVector); Normals.Add(FVector::UpVector); Colors.Add(FColor(0,0,0,255));
    constexpr int Rings=10, Segments=64;
    for(int Ring=1;Ring<=Rings;++Ring) for(int S=0;S<Segments;++S) {
        const float R=float(Ring)/Rings, A=2.f*PI*S/Segments;
        Vertices.Add(FVector(FMath::Cos(A)*24.f*R,FMath::Sin(A)*34.f*R,0));
        Normals.Add(FVector::UpVector);
        Colors.Add(FColor(0,0,0,uint8(255.f*FMath::Square(1-R))));
    }
    for(int S=0;S<Segments;++S) { Indices.Add(0); Indices.Add(1+(S+1)%Segments); Indices.Add(1+S); }
    for(int Ring=1;Ring<Rings;++Ring) for(int S=0;S<Segments;++S) {
        const int A=1+(Ring-1)*Segments+S, B=1+(Ring-1)*Segments+(S+1)%Segments;
        const int C=1+Ring*Segments+S, D=1+Ring*Segments+(S+1)%Segments;
        Indices.Append({A,D,C,A,B,D});
    }
    ContactShadow->CreateMeshSection(0,Vertices,Indices,Normals,TArray<FVector2D>(),Colors,TArray<FProcMeshTangent>(),false);
    ShadowMaterial=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_ContactShadow.M_ContactShadow")),this);
    ContactShadow->SetMaterial(0,ShadowMaterial);
}
UProceduralMeshComponent* AMuseGuardian::SoftBox(FName Name,USceneComponent* Parent,FVector Position,FVector Size,float Radius,FLinearColor Tint) {
    auto* Mesh=NewObject<UProceduralMeshComponent>(this,Name);
    Mesh->SetupAttachment(Parent);Mesh->SetRelativeLocation(Position);
    Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);Mesh->RegisterComponent();
    TArray<FVector> V,N;TArray<int32> I;
    const FVector H=Size*.5, Inner=H-FVector(Radius);
    auto Axis=[Radius](double Half,int Index) {
        const double Edge[5]={0,.15,.5,.85,1};
        return Index<5?-Half+Radius*Edge[Index]:Half-Radius*Edge[9-Index];
    };
    const FVector Normals[6]={FVector(1,0,0),FVector(-1,0,0),FVector(0,1,0),FVector(0,-1,0),FVector(0,0,1),FVector(0,0,-1)};
    for(FVector Face:Normals) {
        const FVector U=FMath::Abs(Face.Z)>.5?FVector(1,0,0):FVector(0,0,1);
        const FVector W=FVector::CrossProduct(Face,U);
        const double HU=FMath::Abs(FVector::DotProduct(H,U)), HW=FMath::Abs(FVector::DotProduct(H,W));
        const int Base=V.Num();
        for(int Y=0;Y<10;++Y) for(int X=0;X<10;++X) {
            const FVector P=Face*FMath::Abs(FVector::DotProduct(H,Face))+U*Axis(HU,X)+W*Axis(HW,Y);
            const FVector Q(FMath::Clamp(P.X,-Inner.X,Inner.X),FMath::Clamp(P.Y,-Inner.Y,Inner.Y),FMath::Clamp(P.Z,-Inner.Z,Inner.Z));
            const FVector Normal=(P-Q).GetSafeNormal();
            V.Add(Q+Normal*Radius);N.Add(Normal);
        }
        for(int Y=0;Y<9;++Y) for(int X=0;X<9;++X) {
            const int A=Base+Y*10+X,B=A+1,C=A+10,D=C+1;
            I.Append({A,C,B,B,C,D});
        }
    }
    Mesh->CreateMeshSection(0,V,I,N,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
    auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_MuseCloth.M_MuseCloth")),this);
    Mat->SetVectorParameterValue(TEXT("Tint"),Tint);Mat->SetVectorParameterValue(TEXT("Glow"),Tint*.025f);
    Mesh->SetMaterial(0,Mat);Materials.Add(Mat);
    return Mesh;
}
void AMuseGuardian::BuildBed() {
    Bed=Joint(TEXT("SleepBed"),RootComponent,FVector::ZeroVector);
    // A low upholstered nest replaces the stacked metal rails. The mattress
    // surface remains at Z=27 so the character's contact pose stays valid.
    SoftBox(TEXT("UpholsteredBase"),Bed,FVector(0,0,8),FVector(158,86,12),5.8f,FLinearColor(.40,.30,.25));
    SoftBox(TEXT("MattressSidewall"),Bed,FVector(0,0,18),FVector(154,82,18),8.5f,FLinearColor(.77,.69,.58));
    auto* Mattress=SoftBox(TEXT("CreamMattress"),Bed,FVector(0,0,22),FVector(151,80,10),4.8f,FLinearColor(.91,.86,.75));
    Mattress->SetCastShadow(false);
    // The barely raised welt reads as a fabric seam rather than another rail.
    SoftBox(TEXT("MattressWelt"),Bed,FVector(0,0,18.8),FVector(155,83,1.2),.55f,FLinearColor(.66,.57,.46));
    SoftBox(TEXT("UpholsteredHeadRest"),Bed,FVector(78,0,28),FVector(12,84,42),5.8f,FLinearColor(.59,.46,.37));

    // A rounded superellipsoid gives the pillow a continuously inflated crown
    // and curved silhouette, with none of the old slab's broad flat panels.
    auto Puff=[&](FName Name,FVector Position,FVector Size,FLinearColor Tint) {
        auto* Mesh=NewObject<UProceduralMeshComponent>(this,Name);
        Mesh->SetupAttachment(Bed);Mesh->SetRelativeLocation(Position);
        Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);Mesh->SetCastShadow(false);Mesh->RegisterComponent();
        TArray<FVector> V,N;TArray<FVector2D> UV;TArray<int32> I;
        constexpr int Rings=32,Segments=64;
        const FVector H=Size*.5;
        auto Power=[](double X,double E) { return FMath::Sign(X)*FMath::Pow(FMath::Abs(X),E); };
        for(int R=0;R<=Rings;++R) {
            const double Phi=-PI*.5+PI*R/Rings;
            for(int S=0;S<=Segments;++S) {
                const double Theta=2*PI*S/Segments;
                const double C=Power(FMath::Cos(Phi),.60);
                FVector P(H.X*C*Power(FMath::Cos(Theta),.65),H.Y*C*Power(FMath::Sin(Theta),.65),H.Z*Power(FMath::Sin(Phi),.60));
                // A tiny center compression suggests a soft filled pillow.
                if(P.Z>0) P.Z-=.55*FMath::Exp(-FMath::Square(P.X/15.)-FMath::Square((P.Y+8)/22.));
                V.Add(P);N.Add(FVector::ZeroVector);UV.Add(FVector2D(double(S)/Segments,double(R)/Rings));
            }
        }
        for(int R=0;R<Rings;++R) for(int S=0;S<Segments;++S) {
            const int A=R*(Segments+1)+S,B=A+1,C=A+Segments+1,D=C+1;
            I.Append({A,C,B,B,C,D});
        }
        for(int K=0;K<I.Num();K+=3) {
            const FVector Normal=FVector::CrossProduct(V[I[K+2]]-V[I[K]],V[I[K+1]]-V[I[K]]);
            for(int C=0;C<3;++C) N[I[K+C]]+=Normal;
        }
        for(auto& Normal:N) Normal.Normalize();
        // Average the duplicated longitude seam to keep its shading invisible.
        for(int R=0;R<=Rings;++R) {
            const int A=R*(Segments+1),B=A+Segments;
            const FVector Normal=(N[A]+N[B]).GetSafeNormal();N[A]=N[B]=Normal;
        }
        Mesh->CreateMeshSection(0,V,I,N,UV,TArray<FColor>(),TArray<FProcMeshTangent>(),false);
        auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_MuseCloth.M_MuseCloth")),this);
        Mat->SetVectorParameterValue(TEXT("Tint"),Tint);Mat->SetVectorParameterValue(TEXT("Glow"),Tint*.025f);
        Mesh->SetMaterial(0,Mat);Materials.Add(Mat);
        return Mesh;
    };
    Pillow=Puff(TEXT("PlumpCreamPillow"),FVector(51,-10,32),FVector(54,84,16),FLinearColor(.96,.91,.81));
    // Recessed feet disappear beneath the padded base instead of drawing a
    // mechanical outline around the character.
    for(int X:{-1,1}) for(int Y:{-1,1})
        SoftBox(*FString::Printf(TEXT("BedFoot_%d_%d"),X,Y),Bed,FVector(X*61,Y*29,2),FVector(9,9,4),1.8f,FLinearColor(.32,.23,.18));
    Bed->SetVisibility(false,true);
}

void AMuseGuardian::BuildMagic() {
    Wand=Joint(TEXT("MagicWand"),Rig,FVector::ZeroVector);
    Part(TEXT("WandHandle"),Wand,FVector(0,0,4),FVector(2.3,2.3,24),FLinearColor(.10,.045,.23),TEXT("Cylinder"))->SetCastShadow(false);
    for(float Z:{-6.f,14.f})
        Part(NAME_None,Wand,FVector(0,0,Z),FVector(2.8,2.8,2),FLinearColor(.9,.57,.12),TEXT("Cylinder"))->SetCastShadow(false);
    // Solid extruded five-point star, readable from the front and the side.
    auto* Star=NewObject<UProceduralMeshComponent>(this,TEXT("WandStar"));
    Star->SetupAttachment(Wand);Star->SetCollisionEnabled(ECollisionEnabled::NoCollision);Star->SetCastShadow(false);Star->RegisterComponent();
    TArray<FVector> V,N;TArray<int32> I;
    for(int Side=0;Side<2;++Side) {
        V.Add(FVector(Side?1.1:-1.1,0,21));
        for(int K=0;K<10;++K) {
            const float A=K*PI/5,R=K%2?2.6f:6.f;
            V.Add(FVector(Side?1.1:-1.1,FMath::Sin(A)*R,21+FMath::Cos(A)*R));
        }
    }
    for(int K=0;K<10;++K) {
        const int A=1+K,B=1+(K+1)%10;
        I.Append({0,A,B,11,B+11,A+11,A,A+11,B+11,A,B+11,B});
    }
    N.SetNumZeroed(V.Num());
    for(int K=0;K<I.Num();K+=3) {
        const FVector Face=FVector::CrossProduct(V[I[K+2]]-V[I[K]],V[I[K+1]]-V[I[K]]);
        for(int C=0;C<3;++C) N[I[K+C]]+=Face;
    }
    for(auto& Normal:N) Normal.Normalize();
    Star->CreateMeshSection(0,V,I,N,TArray<FVector2D>(),TArray<FColor>(),TArray<FProcMeshTangent>(),false);
    auto* Mat=UMaterialInstanceDynamic::Create(LoadObject<UMaterialInterface>(nullptr,TEXT("/Game/Muse/M_Guardian.M_Guardian")),this);
    Mat->SetVectorParameterValue(TEXT("Tint"),FLinearColor(1,.65,.18));
    Mat->SetVectorParameterValue(TEXT("Glow"),FLinearColor(.8,.38,.06));Star->SetMaterial(0,Mat);Materials.Add(Mat);
    for(int K=0;K<28;++K) {
        auto* Mote=Part(NAME_None,RootComponent,FVector::ZeroVector,FVector(2.5),K%2?FLinearColor(.65,.35,1):FLinearColor(1,.7,.22),TEXT("Sphere"),true);
        Mote->SetCastShadow(false);Mote->SetVisibility(false);MagicMotes.Add(Mote);
    }
    Wand->SetVisibility(false,true);
}
void AMuseGuardian::BeginPlay() {
    Super::BeginPlay();
    FParse::Value(FCommandLine::Get(),TEXT("MuseBridge="),BridgeDirectory);
    LastHeartbeat=FPlatformTime::Seconds();
    BuildCharacter();BuildFur();BuildAccessories();BuildContactShadow();BuildBed();BuildMagic();
    YawnMouth=Part(TEXT("YawnMouth"),Head,FVector(33.2,0,13.4),FVector(1.8,5,8),FLinearColor(.025,.008,.014));
    YawnMouth->SetCastShadow(false);YawnMouth->SetVisibility(false);
    // Small continuous arcs replace the button eyes when fully closed.
    // Compressing the surrounding face used to dent the sleeping cheek.
    for(int Side : {-1,1}) for(int K=0;K<17;++K) {
        const float U=-1.f+K/8.f;
        auto* Lid=Part(*FString::Printf(TEXT("ClosedLid_%d_%d"),Side,K),Head,
            FVector(31.0f,Side*10.25f+U*2.25f,18.5f-1.25f*(1-U*U)),
            FVector(.65f,.65f,.65f),FLinearColor(.018,.012,.009));
        Lid->SetCastShadow(false);Lid->SetVisibility(false);ClosedLids.Add(Lid);
    }

    if(GEngine)GEngine->SetMaxFPS(30);
    LightRig=Joint(TEXT("FollowingLights"),RootComponent,FVector::ZeroVector);
    auto* Key=NewObject<UDirectionalLightComponent>(this);Key->SetupAttachment(RootComponent);Key->SetRelativeRotation(FRotator(-30,160,0));Key->SetMobility(EComponentMobility::Movable);Key->SetCastShadows(false);Key->SetIntensity(.8);Key->SetLightSourceAngle(12);Key->RegisterComponent();
    auto* Fill=NewObject<UPointLightComponent>(this);Fill->SetupAttachment(LightRig);Fill->SetRelativeLocation(FVector(130,100,140));Fill->SetMobility(EComponentMobility::Movable);Fill->SetCastShadows(false);Fill->SetIntensity(2200);Fill->SetAttenuationRadius(500);Fill->SetLightColor(FLinearColor(.73,.83,1));Fill->RegisterComponent();
    auto* Rim=NewObject<UPointLightComponent>(this);Rim->SetupAttachment(LightRig);Rim->SetRelativeLocation(FVector(-70,-60,150));Rim->SetMobility(EComponentMobility::Movable);Rim->SetCastShadows(false);Rim->SetIntensity(3200);Rim->SetAttenuationRadius(400);Rim->SetLightColor(FLinearColor(1,.82,.55));Rim->RegisterComponent();
    auto* Bounce=NewObject<UDirectionalLightComponent>(this);Bounce->SetupAttachment(RootComponent);Bounce->SetRelativeRotation(FRotator(22,180,0));Bounce->SetMobility(EComponentMobility::Movable);Bounce->SetIntensity(.55f);Bounce->SetCastShadows(false);Bounce->SetLightColor(FLinearColor(.88,.93,1));Bounce->RegisterComponent();
    // Broad camera-side fill keeps the turned sleeping face and undercoat
    // readable without using emissive glow to wash away surface detail.
    auto* PortraitFill=NewObject<UPointLightComponent>(this);PortraitFill->SetupAttachment(LightRig);PortraitFill->SetRelativeLocation(FVector(110,-180,140));PortraitFill->SetMobility(EComponentMobility::Movable);PortraitFill->SetCastShadows(false);PortraitFill->SetIntensity(3500);PortraitFill->SetAttenuationRadius(550);PortraitFill->SetLightColor(FLinearColor(.94,.97,1));PortraitFill->RegisterComponent();
    auto* BedBounce=NewObject<UPointLightComponent>(this);BedBounce->SetupAttachment(LightRig);BedBounce->SetRelativeLocation(FVector(0,-70,18));BedBounce->SetMobility(EComponentMobility::Movable);BedBounce->SetCastShadows(false);BedBounce->SetIntensity(500);BedBounce->SetAttenuationRadius(220);BedBounce->SetLightColor(FLinearColor(1,.88,.75));BedBounce->RegisterComponent();
    Target=NewObject<UTextureRenderTarget2D>(this);
    Target->RenderTargetFormat=RTF_RGBA16f;
    Target->ClearColor=FLinearColor(0,0,0,1);
    Target->InitAutoFormat(1280,1280);Target->UpdateResourceImmediate(true);
    Capture=NewObject<USceneCaptureComponent2D>(this);Capture->SetupAttachment(RootComponent);
    Capture->SetRelativeLocation(FVector(360,0,112));
    Capture->SetRelativeRotation((FVector(0,0,70)-Capture->GetRelativeLocation()).Rotation());
    Capture->ProjectionType=ECameraProjectionMode::Perspective;Capture->FOVAngle=33;
    Capture->TextureTarget=Target;Capture->CaptureSource=SCS_SceneColorHDR;
    Capture->bCaptureEveryFrame=false;Capture->bCaptureOnMovement=false;
    Capture->ShowFlags.SetAtmosphere(false);Capture->ShowFlags.SetFog(false);Capture->ShowFlags.SetMotionBlur(false);
    Capture->RegisterComponent();
    UE_LOG(LogTemp,Display,TEXT("MUSE_RENDERER_READY bridge=%s"),*BridgeDirectory);
}
void AMuseGuardian::ReadCommand() {
    if(BridgeDirectory.IsEmpty())return;
    FString Text;
    if(FFileHelper::LoadFileToString(Text,*(BridgeDirectory/TEXT("command.json")))) {
        TSharedPtr<FJsonObject> J;
        if(FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(Text),J)) {
            FString NextState;
            if(J->TryGetStringField(TEXT("state"),NextState) && NextState!=State) { State=NextState; StateAge=0; PhaseStart=0; PhaseDuration=State==TEXT("notice")?.48f:(State==TEXT("land")?.38f:1.05f); }
            FString Next; if(J->TryGetStringField(TEXT("accessory"),Next)&&Next!=Accessory) {
                Accessory=Next;
                for(int I=0;I<AccessoryRoots.Num();++I)AccessoryRoots[I]->SetVisibility(AccessoryNames[I]==Accessory);
            }
            J->TryGetBoolField(TEXT("reduceMotion"),ReduceMotion);
            J->TryGetBoolField(TEXT("debugMotion"),DebugMotion);
            double Inspection=0;J->TryGetNumberField(TEXT("inspectionYaw"),Inspection);
            InspectionYaw=DebugMotion?float(Inspection):0;
            double PhaseValue=0;
            if(J->TryGetNumberField(TEXT("phaseStart"),PhaseValue)) PhaseStart=PhaseValue;
            if(J->TryGetNumberField(TEXT("phaseDuration"),PhaseValue)) PhaseDuration=FMath::Clamp(float(PhaseValue),.05f,20.f);
            if(J->TryGetNumberField(TEXT("travelDirection"),PhaseValue)) TravelDirection=FMath::Clamp(float(PhaseValue),-1.f,1.f);
            const TSharedPtr<FJsonObject>* Scene;
            if(J->TryGetObjectField(TEXT("desktopScene"),Scene)) {
                (*Scene)->TryGetBoolField(TEXT("enabled"),DesktopScene);
                if(DesktopScene) {
                    DesktopWidth=FMath::Max(220.f,float((*Scene)->GetNumberField(TEXT("width"))));
                    DesktopHeight=FMath::Max(220.f,float((*Scene)->GetNumberField(TEXT("height"))));
                    FromAnchor=FVector2D((*Scene)->GetNumberField(TEXT("fromX")),(*Scene)->GetNumberField(TEXT("fromY")));
                    ToAnchor=FVector2D((*Scene)->GetNumberField(TEXT("toX")),(*Scene)->GetNumberField(TEXT("toY")));
                    FromScale=FMath::Clamp(float((*Scene)->GetNumberField(TEXT("fromScale"))),.5f,3.f);
                    ToScale=FMath::Clamp(float((*Scene)->GetNumberField(TEXT("toScale"))),.5f,3.f);
                    HomeSize=FMath::Max(100.f,float((*Scene)->GetNumberField(TEXT("homeSize"))));
                }
            } else DesktopScene=false;
            // Render only the occupied region at Retina density, independent of
            // desktop size. The fixed world camera and trajectory stay intact.
            const int W=DesktopScene?int(DesktopTileSize*2):640;
            const int H=W;
            if(W!=OutputWidth || H!=OutputHeight) {
                OutputWidth=W; OutputHeight=H;
                Target->ResizeTarget(W*2,H*2);
            }
            double V=0;if(J->TryGetNumberField(TEXT("gaze"),V))Gaze=FMath::Clamp((float)V,-1.f,1.f);
            double Heartbeat=0;
            if(J->TryGetNumberField(TEXT("heartbeat"),Heartbeat)) {
                double Age=FDateTime::UtcNow().ToUnixTimestamp()-Heartbeat;
                if(Age<10)LastHeartbeat=FPlatformTime::Seconds();
            }
        }
    }
    if(FPlatformTime::Seconds()-LastHeartbeat>30)FPlatformMisc::RequestExit(false);
}
void AMuseGuardian::PoseLeg(int SideIndex, FVector AnkleTarget, FQuat AnkleRotation) {
    const int Hip=4+SideIndex, Knee=8+SideIndex, Ankle=10+SideIndex;
    const FVector H=Pivots[Hip];
    const float Upper=11.f, Lower=8.f;
    FVector Direction=AnkleTarget-H;
    const float Distance=FMath::Clamp(float(Direction.Size()),3.1f,Upper+Lower-.001f);
    Direction=Direction.GetSafeNormal(1.e-8,FVector(0,0,-1));
    AnkleTarget=H+Direction*Distance;
    const float Along=(Upper*Upper-Lower*Lower+Distance*Distance)/(2*Distance);
    const float Out=FMath::Sqrt(FMath::Max(0.f,Upper*Upper-Along*Along));
    const FVector Bend=(FVector::ForwardVector-Direction*FVector::DotProduct(FVector::ForwardVector,Direction)).GetSafeNormal();
    const FVector K=H+Direction*Along+Bend*Out;
    BoneRotations[Hip]=FQuat::FindBetweenNormals(FVector(0,0,-1),(K-H).GetSafeNormal());
    BoneRotations[Knee]=FQuat::FindBetweenNormals(FVector(0,0,-1),(AnkleTarget-K).GetSafeNormal());
    BoneOffsets[Hip]=FVector::ZeroVector;
    BoneOffsets[Knee]=K-Pivots[Knee];
    BoneRotations[Ankle]=AnkleRotation;
    BoneOffsets[Ankle]=AnkleTarget-Pivots[Ankle];
}
void AMuseGuardian::Tick(float DeltaTime) {
    Super::Tick(DeltaTime); Time+=DeltaTime; StateAge+=DeltaTime; ReadElapsed+=DeltaTime;
    if(ReadElapsed>.02f){ReadCommand();ReadElapsed=0;}
    const bool Stop=State==TEXT("stop"), Talk=State==TEXT("explain"), Scan=State==TEXT("scanning");
    const bool Jump=State==TEXT("jump")||State==TEXT("return");
    if(Jump) Returning=State==TEXT("return");
    const bool Notice=State==TEXT("notice"), Land=State==TEXT("land");
    const bool Moving=(Notice||Jump||Land)&&!ReduceMotion;
    const bool Sleeping=(State==TEXT("sleep")||State==TEXT("settle"))&&!DesktopScene;
    const bool Walking=State==TEXT("walk");
    const bool Climbing=State==TEXT("climb");
    const float WalkSpeed=DesktopScene?FVector2D::Distance(FromAnchor,ToAnchor)/PhaseDuration:110.f;
    const float WalkCycle=StateAge*2*PI*FMath::Clamp(WalkSpeed/56.f,1.f,3.f);
    const float ClimbCycle=StateAge*2*PI*FMath::Clamp(WalkSpeed/65.f,.7f,1.5f);
    const float Yawn=ReduceMotion?0.f:((State==TEXT("yawn")||State==TEXT("sleep"))?
        FMath::SmoothStep(.15f,.95f,StateAge)*(1-FMath::SmoothStep(1.9f,2.8f,StateAge)):0.f);
    const float ConjureAge=State==TEXT("sleep")?StateAge-3.f:StateAge;
    if(WasSleeping&&!Sleeping&&SleepAmount>.05f) DismissAge=0;
    else DismissAge+=DeltaTime;
    WasSleeping=Sleeping;
    const float Cast=(!ReduceMotion&&Sleeping)?FMath::SmoothStep(0.f,.20f,ConjureAge)*(1-FMath::SmoothStep(1.25f,1.7f,ConjureAge)):0;
    const float Dismiss=(!ReduceMotion&&!DesktopScene)?FMath::SmoothStep(.28f,.42f,DismissAge)*(1-FMath::SmoothStep(.72f,1.05f,DismissAge)):0;
    const float Spell=FMath::Max(Cast,Dismiss);
    const bool BedReady=Sleeping&&(ReduceMotion||ConjureAge>=.65f);
    const bool Dozy=State==TEXT("drowsy")&&!DesktopScene;
    const bool Resting=State==TEXT("idle")||State==TEXT("stretch")||Dozy;
    SleepAmount=ReduceMotion?(Sleeping?1.f:0.f):FMath::FInterpConstantTo(SleepAmount,BedReady?1.f:0.f,DeltaTime,BedReady?.23f:1.4f);
    if(DesktopScene) SleepAmount=0;
    const float SleepLie=FMath::SmoothStep(.44f,.96f,SleepAmount);
    const float BedStep=FMath::SmoothStep(.12f,.38f,SleepAmount);
    const float BedAppear=FMath::SmoothStep(0.f, Sleeping?.18f:.40f,SleepAmount);
    const FVector RumpGoal=(Walking&&!ReduceMotion)?FVector(.35f*FMath::Sin(2*WalkCycle),1.2f*FMath::Sin(WalkCycle),.65f*FMath::Sin(2*WalkCycle-.4f)):FVector::ZeroVector;
    if(ReduceMotion||SleepAmount>.01f) { RumpOffset=FVector::ZeroVector;RumpVelocity=FVector::ZeroVector; }
    else {
        // Underdamped secondary motion lags each footfall and settles after
        // stopping. Fixed substeps keep the bounce stable on slower frames.
        const int Steps=FMath::Max(1,FMath::CeilToInt(DeltaTime*120));
        const float Dt=FMath::Min(DeltaTime,.10f)/Steps;
        for(int K=0;K<Steps;++K) { RumpVelocity+=(324.f*(RumpGoal-RumpOffset)-15.12f*RumpVelocity)*Dt;RumpOffset+=RumpVelocity*Dt; }
        RumpOffset=RumpOffset.GetClampedToMaxSize(2.2);
    }
    const float Breathe=ReduceMotion?0.f:FMath::Sin(Time*1.25f);
    const float IdleCycle=FMath::Fmod(StateAge,22.f);
    const float Stretch=(Resting&&!ReduceMotion&&!Dozy)?(State==TEXT("stretch")?.5f+.5f*FMath::Sin(Time*1.2f):FMath::Sin(PI*FMath::Clamp((IdleCycle-10.f)/4.f,0.f,1.f))):0.f;
    Bed->SetVisibility(SleepAmount>.001f,true);
    Bed->SetRelativeScale3D(FVector(FMath::Max(.001f,BedAppear)));
    Bed->SetRelativeLocation(FVector(0,0,-12.f*(1-BedAppear)));
    Pillow->SetRelativeScale3D(FVector(1,1,1-.07f*SleepLie+.01f*SleepLie*Breathe));
    for(int I=0;I<AccessoryRoots.Num();++I) AccessoryRoots[I]->SetVisibility(AccessoryNames[I]==Accessory&&SleepAmount<.25f);
    const float Orbit=ReduceMotion?(Sleeping?1.f:0.f):(Sleeping?
        FMath::SmoothStep(0.f,.65f,ConjureAge):FMath::Max(FMath::SmoothStep(0.f,.75f,SleepAmount),1-FMath::SmoothStep(.55f,.85f,DismissAge)));
    const float Angle=FMath::DegreesToRadians(-123.f*Orbit+InspectionYaw), Radius=FMath::Lerp(360.f,410.f,Orbit);
    const FVector IdleCamera(Radius*FMath::Cos(Angle),Radius*FMath::Sin(Angle),FMath::Lerp(112.f,230.f,Orbit));
    Capture->SetRelativeLocation(IdleCamera);
    Capture->SetRelativeRotation((FVector(0,0,FMath::Lerp(70.f,74.f,Orbit))-IdleCamera).Rotation());
    Capture->FOVAngle=FMath::Lerp(33.f,38.f,Orbit);
    const FDateTime Now=FDateTime::UtcNow();
    const double Epoch=double(Now.ToUnixTimestamp())+Now.GetMillisecond()/1000.;
    const float Phase=FMath::Clamp(float(PhaseStart>0?Epoch-PhaseStart:StateAge)/PhaseDuration,0.f,1.f);
    auto Ease=[](float A,float B,float V){return FMath::SmoothStep(A,B,V);};
    // Raise the blocking palms before touchdown, not after a floating pause.
    const float BlockPose=(Stop||Talk||(Land&&!Returning))?1.f:
        ((DesktopScene&&State==TEXT("jump"))?Ease(.56f,.90f,Phase):0.f);
    Damped(Pose,PoseVelocity,BlockPose,13.f,DeltaTime);
    SmoothGaze=FMath::FInterpTo(SmoothGaze,Gaze,DeltaTime,3.f);
    float Compression=0, Push=0, Tuck=0, Arc=0, ToePitch=0, Yaw=0, Pitch=0, Roll=0;
    FVector Location=FVector::ZeroVector;
    if(Moving&&Notice) {
        Compression=Ease(0,.60f,Phase)*(1-Ease(.72f,1,Phase));
        Push=Ease(.82f,1,Phase);
        Location=FVector(-2.f*Compression,0,-5.f*Compression+2.f*Push);
        Pitch=-6.f*Compression-5.f*Push;
        Yaw=TravelDirection*18.f*Ease(.3f,1,Phase);
        Roll=-TravelDirection*2.f*Push;
        ToePitch=-18.f*Push;
    } else if(Moving&&Jump) {
        Arc=FMath::Sin(PI*Phase);
        Tuck=Ease(.08f,.38f,Phase)*(1-Ease(.62f,.94f,Phase));
        // Actual translation in the perspective 3D scene, including depth.
        Location=FVector(20.f*Arc,0,24.f*4.f*Phase*(1-Phase)+2.f*(1-Phase));
        const float FaceLanding=1-Ease(.72f,1,Phase);
        Yaw=TravelDirection*(18.f+22.f*Arc)*FaceLanding;
        Pitch=(-5.f-5.f*Arc)*FaceLanding;
        Roll=-TravelDirection*(2.f+5.f*Arc)*FaceLanding;
        ToePitch=-24.f*(1-Ease(.60f,.95f,Phase));
    } else if(Moving&&Land) {
        Compression=FMath::Sin(PI*Phase);
        Location=FVector(-Compression,0,-5.f*Compression);
        Pitch=4.f*Compression;
    } else {
        Location.Z=ReduceMotion?0:FMath::Sin(Time*1.8f)*.3f;
        if(Resting&&!ReduceMotion) {
            Location.Y=FMath::Sin(Time*.65f)*.8f;
            Roll=FMath::Sin(Time*.65f)*1.1f;
            Yaw=FMath::Sin(Time*.32f)*4.f;
            Pitch=Stretch*-3.f;
        }
    }
    if(Walking&&!ReduceMotion) {
        Yaw=-TravelDirection*70.f;Location.Z=-2.f+FMath::Abs(FMath::Sin(WalkCycle))*.65f;
        Roll=FMath::Sin(WalkCycle)*1.2f;
    }
    if(Climbing&&!ReduceMotion) {
        // Face the screen edge, reach up and pull with opposite hand/foot pairs.
        // Use the same world-space path and scale as walking, never a UI slide.
        const float Grip=Ease(0,.08f,Phase)*(1-Ease(.92f,1,Phase));
        Yaw=145.f*Grip;Pitch=-5.f*Grip;
        Location.Y=FMath::Sin(ClimbCycle)*1.2f*Grip;
        Roll=FMath::Sin(ClimbCycle)*2.f*Grip;
        Location.Z=FMath::Sin(ClimbCycle*2)*.6f*Grip;
    }
    Pitch-=Yawn*3.f;Location.Z+=Yawn*.5f;
    if(SleepAmount>0) {
        const FVector BedPose(-50.f*SleepLie,0,27.f*BedStep+27.f*SleepLie+7.f*FMath::Sin(PI*SleepLie)+SleepLie*Breathe*.35f);
        Location=FMath::Lerp(Location,BedPose,FMath::Min(1.f,SleepAmount*8));
        Pitch=FMath::Lerp(Pitch,-90.f,SleepLie);Yaw*=1-SleepLie;Roll*=1-SleepLie;
    }
    // The same stationary camera renders the complete desktop journey.
    // Unproject the endpoint rays at different depths, then fly between the
    // world points with constant horizontal momentum and a ballistic rise.
    FVector WorldBase=FVector::ZeroVector, WorldTravel=FVector::ZeroVector;
    float TravelProgress=0, PerspectiveScale=1, WorldArc=0;
    if(DesktopScene) {
        const FVector Camera=Capture->GetRelativeLocation();
        const FQuat CameraRotation=Capture->GetRelativeRotation().Quaternion();
        const FVector Forward=CameraRotation.GetForwardVector(), Right=CameraRotation.GetRightVector(), Up=CameraRotation.GetUpVector();
        const float TanHalf=FMath::Tan(FMath::DegreesToRadians(Capture->FOVAngle*.5f));
        const float BaseDepth=FVector::Distance(Camera,FVector(0,0,70))*DesktopWidth/HomeSize;
        auto Unproject=[&](FVector2D Anchor,float Scale) {
            const float Depth=BaseDepth/Scale;
            return Camera+Forward*Depth+Right*((Anchor.X/DesktopWidth*2-1)*Depth*TanHalf)
                +Up*((Anchor.Y/DesktopHeight*2-1)*Depth*TanHalf*DesktopHeight/DesktopWidth)-FVector(0,0,70);
        };
        const FVector Start=Unproject(FromAnchor,FromScale), End=Unproject(ToAnchor,ToScale);
        TravelProgress=(Jump||Walking||Climbing)?Phase:((Notice||State==TEXT("prepare"))?0.f:1.f);
        if(ReduceMotion) TravelProgress=Ease(0,1,TravelProgress);
        WorldBase=FMath::Lerp(Start,End,TravelProgress);
        WorldArc=ReduceMotion?0.f:(Jump?100.f*4.f*Phase*(1-Phase):0.f);
        WorldTravel=WorldBase+FVector(0,0,WorldArc);
        PerspectiveScale=1.f/FMath::Lerp(1.f/FromScale,1.f/ToScale,TravelProgress);
        // The arc is now above the desktop path, not a small hop inside a tile.
        if(Jump) Location=FVector(0,0,ReduceMotion?0.f:2.f*(1-Phase));
    }
    TravelRoot->SetRelativeLocation(WorldTravel);
    LightRig->SetRelativeLocation(WorldTravel);
    Rig->SetRelativeScale3D(FVector(1+SleepLie*Breathe*.008f+Yawn*.018f,1+Yawn*.012f,1));
    Rig->SetRelativeLocation(Location);
    Rig->SetRelativeRotation(FRotator(Pitch,Yaw,Roll));
    const FTransform RootPose=Rig->GetRelativeTransform();
    const float AirHeight=FMath::Max(0.f,float(Location.Z));
    ContactShadow->SetRelativeLocation(WorldBase+FVector(Location.X,0,-.25f));
    ContactShadow->SetRelativeScale3D(FVector(1+(AirHeight+WorldArc)*.018f,1+(AirHeight+WorldArc)*.018f,1));
    ShadowMaterial->SetScalarParameterValue(TEXT("Opacity"),SleepAmount>.01f?.15f:.18f*FMath::Exp(-(AirHeight+WorldArc)/45.f));
    if(SleepAmount>.01f) {
        ContactShadow->SetRelativeLocation(FVector(0,0,-.25f));
        ContactShadow->SetRelativeScale3D(FMath::Lerp(FVector::OneVector,FVector(3.4,1.6,1),BedAppear));
        if(BedAppear>.99f) {
            ContactShadow->SetRelativeLocation(FVector(4,0,27.12f));
            ContactShadow->SetRelativeScale3D(FVector(2.6f,.95f,1));
            ShadowMaterial->SetScalarParameterValue(TEXT("Opacity"),.24f*SleepLie);
        }
    }
    const float ScanLook=Scan&&!ReduceMotion?FMath::Sin(Time*.85f)*9.f:0;
    const float Curious=Resting&&!ReduceMotion?FMath::Sin(PI*FMath::Clamp((IdleCycle-3.f)/5.f,0.f,1.f))*22.f:0;
    FQuat HeadTarget=ReduceMotion?FQuat::Identity:FRotator((Dozy?-8.f-4.f*FMath::Sin(Time*.8f):0)+(Talk?FMath::Sin(Time*3.4f)*2.f:0)+Compression*3.f+Yawn*5.f,SmoothGaze*7.f+ScanLook+Curious-Yaw*.18f,FMath::Sin(Time*1.2f)*1.2f+(Scan?4.f:0)).Quaternion();
    const FQuat SleepHead=RootPose.GetRotation().Inverse()*RestingHeadRotation();
    HeadTarget=FQuat::Slerp(HeadTarget,SleepHead,SleepLie);
    BoneRotations[1]=FQuat::Slerp(BoneRotations[1],HeadTarget,1-FMath::Exp(-DeltaTime*6.f));
    const FVector HeadSocket=FVector(43,-12,52)-RestingHeadRotation().RotateVector(FVector(0,0,96)-Pivots[1]);
    BoneOffsets[1]=(RootPose.InverseTransformPosition(HeadSocket)-Pivots[1])*SleepLie;
    Head->SetRelativeLocation(Pivots[1]+BoneOffsets[1]);
    Head->SetRelativeRotation(BoneRotations[1]);
    for(int I=0;I<2;++I) {
        const float Side=I==0?-1.f:1.f;
        const float Gesture=Talk&&!ReduceMotion?(I==0?-.15f:.1f*FMath::Sin(Time*2.5f)):0;
        float ArmSwing=0, ArmSpread=0;
        if(Moving&&Notice) { ArmSwing=-24.f*Compression+38.f*Push; ArmSpread=6.f*Compression; }
        if(Moving&&Jump) { ArmSwing=(38.f+24.f*Tuck)*(1-Pose); ArmSpread=(20.f+10.f*Tuck)*(1-Pose); }
        if(Moving&&Land) { ArmSwing=24.f*Compression*(1-Pose); ArmSpread=12.f*Compression*(1-Pose); }
        FQuat ArmTarget=FRotator(Pose*((I==0?106.f:101.f)+Gesture*25.f)+ArmSwing+Stretch*60.f,Side*Pose*12.f,-Side*(Pose*18.f+ArmSpread+Stretch*110.f+(ReduceMotion?0:FMath::Sin(Time*1.8f+I*.5f)*1.4f))).Quaternion();
        if(Walking&&!ReduceMotion) ArmTarget=FRotator(FMath::Sin(WalkCycle+I*PI)*16.f,0,-Side*5.f).Quaternion();
        if(Climbing&&!ReduceMotion) {
            const float Reach=FMath::Sin(ClimbCycle+I*PI);
            const FVector Grip(10.f,Side*47.f,84.f+27.f*Reach);
            const FQuat ClimbArm=FQuat::FindBetweenNormals((Pivots[6+I]-Pivots[2+I]).GetSafeNormal(),(Grip-Pivots[2+I]).GetSafeNormal());
            ArmTarget=FQuat::Slerp(ArmTarget,ClimbArm,Ease(0,.08f,Phase)*(1-Ease(.92f,1,Phase)));
        }
        const FQuat YawnArm=I==0?FQuat::FindBetweenNormals((Pivots[6]-Pivots[2]).GetSafeNormal(),FVector(25,22,18).GetSafeNormal()):FRotator(20,0,-8).Quaternion();
        BoneOffsets[2+I]=I==0?FVector(4,5,5)*Yawn:FVector::ZeroVector;
        ArmTarget=FQuat::Slerp(ArmTarget,YawnArm,Yawn);
        const float Reach=FMath::SmoothStep(.28f,.67f,SleepAmount);
        const FQuat PillowReach=FQuat::FindBetweenNormals((Pivots[6+I]-Pivots[2+I]).GetSafeNormal(),(FVector(12,Side*38,83)-Pivots[2+I]).GetSafeNormal());
        ArmTarget=FQuat::Slerp(ArmTarget,PillowReach,Reach);
        if(I==0&&Spell>.001f) {
            const float Flick=FMath::Sin((Cast>0?ConjureAge:DismissAge)*7.f);
            const FVector Grip(23,-47,60+10*Flick);
            const FQuat CastArm=FQuat::FindBetweenNormals((Pivots[6]-Pivots[2]).GetSafeNormal(),(Grip-Pivots[2]).GetSafeNormal());
            ArmTarget=FQuat::Slerp(ArmTarget,CastArm,Spell*(1-SleepLie));
        }
        BoneRotations[2+I]=FQuat::Slerp(BoneRotations[2+I],ArmTarget,1-FMath::Exp(-DeltaTime*11.f));
        const FQuat PalmFacing=FRotator(155.f,0,Side*5.f).Quaternion();
        BoneRotations[6+I]=FQuat::Slerp(BoneRotations[2+I],PalmFacing,Pose);
        BoneOffsets[6+I]=Pivots[2+I]+BoneOffsets[2+I]+BoneRotations[2+I].RotateVector(Pivots[6+I]-Pivots[2+I])-Pivots[6+I];
        // Fold the soft mittens below the cheek, clear of the closed eyes.
        BoneOffsets[6+I]=FMath::Lerp(BoneOffsets[6+I],FVector(12,Side*38,83)-Pivots[6+I],SleepLie);
        FVector AnkleTarget;
        FQuat FootRotation;
        if(Walking&&!ReduceMotion) {
            const float Step=WalkCycle+I*PI;
            AnkleTarget=FVector(FMath::Cos(Step)*7.f,Side*16.4f,3.f+FMath::Max(0.f,FMath::Sin(Step))*5.f);
            FootRotation=FRotator(FMath::Sin(Step)*8.f,0,0).Quaternion();
        } else if(Climbing&&!ReduceMotion) {
            const float Step=ClimbCycle+I*PI;
            const float Grip=Ease(0,.08f,Phase)*(1-Ease(.92f,1,Phase));
            AnkleTarget=FMath::Lerp(FVector(0,Side*16.4f,3),FVector(12.f,Side*17.f,14.f+4.f*FMath::Max(0.f,-FMath::Sin(Step))),Grip);
            FootRotation=FRotator(-12.f*Grip,0,0).Quaternion();
        } else if(SleepAmount>.001f) {
            const float StepLift=ReduceMotion?0:8.f*FMath::Sin(PI*FMath::Clamp((SleepAmount-(I==0?.10f:.20f))/.20f,0.f,1.f))*(1-SleepLie);
            AnkleTarget=FVector(15.f*SleepLie,Side*(16.4f+1.5f*SleepLie),3.f+7.f*SleepLie+StepLift);
            FootRotation=FRotator(0,0,Side*3.f*SleepLie).Quaternion();
        } else if(Moving&&Jump) {
            const float LegTuck=Tuck*(I==0?1.f:.92f);
            AnkleTarget=FVector(-5.5f*LegTuck,Side*(16.4f+2.f*LegTuck),3.f+12.f*LegTuck);
            FootRotation=FRotator(ToePitch,0,Side*5.f*LegTuck).Quaternion();
        } else {
            // Plant both feet in world space while the hips drop and rise.
            // Root rotation is removed from the feet, preserving ground contact.
            AnkleTarget=RootPose.InverseTransformPosition(FVector(0,Side*16.4f,3.f+2.f*Push));
            FootRotation=RootPose.GetRotation().Inverse()*FRotator(ToePitch,0,0).Quaternion();
        }
        PoseLeg(I,AnkleTarget,FootRotation);
    }
    JointCorrection=FMath::Max(FMath::Max(Pose,FMath::Max(Stretch,Yawn)),Moving||Walking||Climbing||SleepAmount>.01f?1.f:0.f);
    const float BlinkPhase=FMath::Fmod(Time,4.7f);
    const float AwakeBlink=BlinkPhase<.18f?FMath::Sin(BlinkPhase/.18f*PI):0;
    const float Blink=FMath::Lerp(FMath::Max(Yawn*.9f,FMath::Max(AwakeBlink,Dozy?.5f+.25f*FMath::Sin(Time*.7f):0.f)),1.f,SleepLie);
    CharacterMesh->SetMeshSectionVisible(1,Blink<.85f);
    for(auto* Lid:ClosedLids) Lid->SetVisibility(Blink>=.85f);
    AnimateMesh(Blink,Talk?FMath::Max(0.f,FMath::Sin(Time*5.f)):0);
    UpdateFur();
    const bool CarryWand=!Sleeping&&SleepAmount<.01f&&!Climbing&&!Moving&&!Stop&&!Talk&&Yawn<.05f;
    const float WandAmount=CarryWand?1.f:Spell*(1-SleepLie);
    const FVector WandGrip=Pivots[6]+BoneOffsets[6]+BoneRotations[6].RotateVector(FVector(10.5,-2,-5));
    const float MagicAge=Cast>0?ConjureAge:DismissAge;
    const FVector WandAim=FMath::Lerp(FVector(.12,-.12,1),FVector(.9,-.25,.15+.6*FMath::Sin(MagicAge*7)),double(Spell)).GetSafeNormal();
    Wand->SetRelativeLocation(WandGrip);Wand->SetRelativeRotation(FQuat::FindBetweenNormals(FVector::UpVector,WandAim));
    Wand->SetRelativeScale3D(FVector(FMath::Max(.001f,WandAmount)));Wand->SetVisibility(WandAmount>.01f,true);
    const FVector Tip=Wand->GetComponentTransform().TransformPosition(FVector(0,0,21));
    const float Dust=(!ReduceMotion&&!DesktopScene)?Spell:0;
    for(int K=0;K<MagicMotes.Num();++K) {
        const float U=FMath::Fmod(MagicAge*.85f+K*.618034f,1.f),A=K*2.39996f;
        const FVector Destination(FMath::Cos(A)*68,FMath::Sin(A)*32,8+U*34);
        const FVector Position=K<8?FMath::Lerp(Tip,Destination,double(U)):Destination;
        MagicMotes[K]->SetRelativeLocation(Position);
        const float Size=Dust*FMath::Sin(PI*U)*(K%3==0?4.2f:2.8f);
        MagicMotes[K]->SetRelativeScale3D(FVector(FMath::Max(.0001f,Size/100.f)));
        MagicMotes[K]->SetVisibility(Size>.1f);
    }
    CharacterMesh->SetMeshSectionVisible(2,Yawn<.12f);
    YawnMouth->SetVisibility(Yawn>=.12f);
    YawnMouth->SetRelativeScale3D(FVector(.018f,.035f+.03f*Yawn,.008f+.085f*Yawn));
    Capture->bUseCustomProjectionMatrix=DesktopScene;
    if(DesktopScene) {
        // Off-axis crop of the fixed desktop camera, not a camera following
        // or scaling the actor. Pixels + their desktop rectangle are atomic.
        const FVector CP=Capture->GetComponentTransform().InverseTransformPosition(WorldTravel+Location+FVector(0,0,70));
        const double HalfFOV=FMath::DegreesToRadians(Capture->FOVAngle*.5);
        const double TanHalf=FMath::Tan(HalfFOV);
        const double CX=DesktopWidth*(.5+.5*CP.Y/(CP.X*TanHalf));
        const double CY=DesktopHeight*.5+DesktopWidth*.5*CP.Z/(CP.X*TanHalf);
        FrameOrigin=FVector2D(FMath::FloorToDouble((CX-DesktopTileSize*.5)*2)/2,FMath::FloorToDouble((CY-DesktopTileSize*.5)*2)/2);
        const double NX=2*(FrameOrigin.X+DesktopTileSize*.5)/DesktopWidth-1;
        const double NY=2*(FrameOrigin.Y+DesktopTileSize*.5)/DesktopHeight-1;
        FMatrix Projection=FReversedZPerspectiveMatrix(HalfFOV,double(DesktopWidth),double(DesktopHeight),10.0);
        Projection.M[0][0]*=DesktopWidth/DesktopTileSize;
        Projection.M[1][1]*=DesktopHeight/DesktopTileSize;
        Projection.M[2][0]=-NX*DesktopWidth/DesktopTileSize;
        Projection.M[2][1]=-NY*DesktopHeight/DesktopTileSize;
        Capture->CustomProjectionMatrix=Projection;
    }
    if(DebugMotion&&!BridgeDirectory.IsEmpty()) {
        auto J=MakeShared<FJsonObject>();
        J->SetNumberField(TEXT("rumpSway"),RumpOffset.Y);J->SetNumberField(TEXT("rumpBounce"),RumpOffset.Z);
        J->SetNumberField(TEXT("magicCast"),Cast);J->SetNumberField(TEXT("magicDismiss"),Dismiss);
        J->SetNumberField(TEXT("bedScale"),BedAppear);J->SetNumberField(TEXT("wandAmount"),WandAmount);
        J->SetBoolField(TEXT("climbing"),Climbing);J->SetNumberField(TEXT("yawn"),Yawn);J->SetNumberField(TEXT("furTufts"),FurRoots.Num());
        if(SleepLie>.99f&&!Skin.IsEmpty()) {
            double Lowest=1.e9,BodyTop=-1.e9,FootLow=1.e9;
            for(int V=0;V<Skin[0].Rest.Num();++V) {
                const auto& R=Skin[0].Rest[V];
                const double WorldZ=RootPose.TransformPosition(Skin[0].Positions[V]).Z;
                if(R.SleepGroup==0&&R.Position.Z>30&&R.Position.Z<70) BodyTop=FMath::Max(BodyTop,WorldZ);
                if(R.SleepGroup==0&&R.Position.Z<10) FootLow=FMath::Min(FootLow,WorldZ);
                if(R.Position.X>10 && R.Position.Z>30 && R.Position.Z<75 && FMath::Abs(R.Position.Y)<24 && R.Weights[0]>.85)
                    Lowest=FMath::Min(Lowest,RootPose.TransformPosition(Skin[0].Positions[V]).Z);
            }
            J->SetNumberField(TEXT("bellyMattressClearance"),Lowest-27.);
            J->SetNumberField(TEXT("restingBodyTop"),BodyTop);J->SetNumberField(TEXT("restingFootLow"),FootLow);
        }
        J->SetNumberField(TEXT("sleepAmount"),SleepAmount);J->SetNumberField(TEXT("sleepLie"),SleepLie);
        J->SetNumberField(TEXT("cameraYaw"),Capture->GetRelativeRotation().Yaw);
        J->SetNumberField(TEXT("bodyPitch"),Pitch);J->SetNumberField(TEXT("eyeClosure"),Blink);
        J->SetNumberField(TEXT("stretch"),Stretch);J->SetNumberField(TEXT("breath"),Breathe*SleepLie);
        J->SetStringField(TEXT("state"),State); J->SetNumberField(TEXT("phase"),Phase);
        J->SetNumberField(TEXT("depth"),Location.X); J->SetNumberField(TEXT("height"),Location.Z);
        J->SetNumberField(TEXT("yaw"),Yaw); J->SetNumberField(TEXT("tuck"),Tuck);
        J->SetStringField(TEXT("projection"),TEXT("perspective"));
        J->SetBoolField(TEXT("desktopScene"),DesktopScene);
        J->SetNumberField(TEXT("travelProgress"),TravelProgress);
        J->SetNumberField(TEXT("perspectiveScale"),PerspectiveScale);
        J->SetNumberField(TEXT("worldArc"),WorldArc);
        J->SetNumberField(TEXT("worldX"),WorldTravel.X);
        J->SetNumberField(TEXT("worldY"),WorldTravel.Y);
        J->SetNumberField(TEXT("worldZ"),WorldTravel.Z);
        J->SetNumberField(TEXT("blockPose"),Pose);
        const FVector CameraPoint=Capture->GetComponentTransform().InverseTransformPosition(WorldTravel+FVector(0,0,70));
        const float ProjectTan=FMath::Tan(FMath::DegreesToRadians(Capture->FOVAngle*.5f));
        J->SetNumberField(TEXT("projectedX"),DesktopWidth*(.5f+.5f*CameraPoint.Y/(CameraPoint.X*ProjectTan)));
        J->SetNumberField(TEXT("projectedY"),DesktopHeight*.5f+DesktopWidth*.5f*CameraPoint.Z/(CameraPoint.X*ProjectTan));
        for(int I=0;I<2;++I) {
            const FVector Hand=Pivots[6+I]+BoneOffsets[6+I];
            J->SetNumberField(I==0?TEXT("leftHandHeight"):TEXT("rightHandHeight"),Hand.Z);
            const FVector Ankle=RootPose.TransformPosition(Pivots[10+I]+BoneOffsets[10+I]);
            J->SetNumberField(I==0?TEXT("leftAnkleHeight"):TEXT("rightAnkleHeight"),Ankle.Z);
            J->SetNumberField(I==0?TEXT("leftKneeBend"):TEXT("rightKneeBend"),FMath::RadiansToDegrees(BoneRotations[4+I].AngularDistance(BoneRotations[8+I])));
        }
        FString Text;FJsonSerializer::Serialize(J,TJsonWriterFactory<>::Create(&Text));
        const FString Temp=BridgeDirectory/TEXT("motion.tmp"), Final=BridgeDirectory/TEXT("motion.json");
        if(FFileHelper::SaveStringToFile(Text,*Temp))std::rename(TCHAR_TO_UTF8(*Temp),TCHAR_TO_UTF8(*Final));
    }
    PublishFrame();
}
void AMuseGuardian::PublishFrame() {
    if(BridgeDirectory.IsEmpty()||!Capture)return;
    Capture->CaptureScene();
    TArray<FLinearColor> Pixels;
    // UNorm rescales HDR pixels against the brightest highlight, crushing the
    // plush body into grey. Read scene-linear values and tone-map explicitly.
    FReadSurfaceDataFlags Flags(RCM_MinMax);Flags.SetLinearToGamma(false);
    if(!Target->GameThread_GetRenderTargetResource()->ReadLinearColorPixels(Pixels,Flags))return;
    const int HeaderSize=DesktopScene?40:24;
    TArray<uint8> Bytes;Bytes.SetNumUninitialized(HeaderSize+OutputWidth*OutputHeight*4);
    uint32 Header[6]={0x4D555345,DesktopScene?2u:1u,uint32(OutputWidth),uint32(OutputHeight),++FrameNumber,(DesktopScene?1u:0u)|(SleepAmount>.001f?2u:0u)};
    FMemory::Memcpy(Bytes.GetData(),Header,24);
    if(DesktopScene) {
        const float Rect[4]={float(FrameOrigin.X),float(FrameOrigin.Y),DesktopTileSize,DesktopTileSize};
        FMemory::Memcpy(Bytes.GetData()+24,Rect,16);
    }
    // Render at 2x resolution and box-filter premultiplied scene-linear color
    // and inverse alpha together. This removes shimmering silhouette edges
    // without temporal ghosting on the transparent desktop overlay.
    ParallelFor(OutputHeight,[&](int Y) {
      uint8* Dest=Bytes.GetData()+HeaderSize+Y*OutputWidth*4;
      for(int X=0;X<OutputWidth;++X){
        const int Stride=OutputWidth*2, Index=(Y*2)*Stride+X*2;
        const FLinearColor P=(Pixels[Index]+Pixels[Index+1]+Pixels[Index+Stride]+Pixels[Index+Stride+1])*.25f;
        const float Alpha=FMath::Clamp(1-P.A,0.f,1.f);
        if(Alpha<.0001f) { FMemory::Memzero(Dest,4); Dest+=4; continue; }
        auto Tone=[Alpha](float C){
            const float X=FMath::Max(0.f,C)/FMath::Max(Alpha,.01f);
            return FMath::Clamp((X*(2.51f*X+.03f))/(X*(2.43f*X+.59f)+.14f),0.f,1.f);
        };
        const FColor Color=FLinearColor(Tone(P.R),Tone(P.G),Tone(P.B),Alpha).ToFColorSRGB();
        *Dest++=Color.R;*Dest++=Color.G;*Dest++=Color.B;*Dest++=Color.A;
      }
    });
    const FString Temp=BridgeDirectory/TEXT("frame.tmp");
    const FString Final=BridgeDirectory/TEXT("frame.rgba");
    // POSIX rename replaces the previous frame atomically. IFileManager::Move
    // can remove the destination first, leaving a gap at exactly a UI poll.
    if(FFileHelper::SaveArrayToFile(Bytes,*Temp)) {
        if(std::rename(TCHAR_TO_UTF8(*Temp),TCHAR_TO_UTF8(*Final))!=0)
            UE_LOG(LogTemp,Warning,TEXT("Could not publish Muse frame atomically"));
    }
}
