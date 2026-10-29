#pragma once
#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "GameFramework/GameModeBase.h"
#include "MuseGuardian.generated.h"

class UStaticMeshComponent;
class UProceduralMeshComponent;

struct FMuseSkinVertex {
    FVector Position, Normal;
    float Weights[12];
    int SleepGroup=0;
};
struct FMuseSkinSection {
    TArray<FMuseSkinVertex> Rest;
    TArray<FVector> Positions, Normals;
    TArray<FVector2D> UVs;
    TArray<FColor> Colors;
    TArray<int32> Indices;
    TArray<int32> SmoothVertices;
    TArray<TArray<int32>> Neighbors;
    TArray<float> SmoothMask;
    TArray<FVector> Smoothed;
};
struct FMuseFurRoot {
    int A, B, C;
    FVector Bary;
    float Length, Width;
    FVector2D RibbonAxis, Groom;
    float Bend;
};
class UMaterialInstanceDynamic;
class USceneCaptureComponent2D;
class UTextureRenderTarget2D;

UCLASS()
class AMuseGuardian : public AActor {
    GENERATED_BODY()
public:
    AMuseGuardian();
    virtual void BeginPlay() override;
    virtual void Tick(float DeltaTime) override;
private:
    UPROPERTY() USceneComponent* Rig;
    UPROPERTY() USceneComponent* TravelRoot;
    UPROPERTY() USceneComponent* LightRig;
    UPROPERTY() USceneComponent* Bed;
    UPROPERTY() USceneComponent* Pillow;
    UPROPERTY() USceneComponent* Wand;
    UPROPERTY() TArray<UStaticMeshComponent*> MagicMotes;
    FVector RumpOffset=FVector::ZeroVector, RumpVelocity=FVector::ZeroVector;
    float DismissAge=99.f;
    bool WasSleeping=false;
    void BuildMagic();
    UPROPERTY() USceneComponent* Head;
    UPROPERTY() UProceduralMeshComponent* CharacterMesh;
    UPROPERTY() UProceduralMeshComponent* FurMesh;
    UPROPERTY() UStaticMeshComponent* YawnMouth;
    UPROPERTY() TArray<UStaticMeshComponent*> ClosedLids;
    TArray<FMuseFurRoot> FurRoots;
    TArray<FVector> FurPositions, FurNormals;
    TArray<int32> FurIndices;
    TArray<FColor> FurColors;
    UPROPERTY() UProceduralMeshComponent* ContactShadow;
    UPROPERTY() UMaterialInstanceDynamic* ShadowMaterial;
    TArray<FMuseSkinSection> Skin;
    FVector SleepTailCentre=FVector(-54,0,45);
    FQuat BoneRotations[12];
    FVector BoneOffsets[12];
    UPROPERTY() USceneCaptureComponent2D* Capture;
    UPROPERTY() UTextureRenderTarget2D* Target;
    UPROPERTY() TArray<USceneComponent*> AccessoryRoots;
    UPROPERTY() TArray<UMaterialInstanceDynamic*> Materials;
    TArray<FString> AccessoryNames;
    FString BridgeDirectory;
    FString State = TEXT("idle");
    FString Accessory = TEXT("guard");
    float Time = 0, Pose = 0, ReadElapsed = 0, StateAge = 0, SmoothGaze = 0, Flight = 0;
    float PoseVelocity = 0, FlightVelocity = 0, CrouchAmount = 0, LandingAmount = 0, Turn = 0;
    double LastHeartbeat = 0, PhaseStart = 0;
    float PhaseDuration = 1.05f, TravelDirection = 1, JointCorrection = 0;
    bool DebugMotion = false;
    uint32 FrameNumber = 0;
    float Gaze = 0;
    float InspectionYaw = 0;
    bool ReduceMotion = false;
    bool DesktopScene = false;
    bool Returning = false;
    int OutputWidth = 640, OutputHeight = 640;
    float DesktopWidth = 1728, DesktopHeight = 1080, HomeSize = 220;
    FVector2D FromAnchor, ToAnchor;
    float FromScale = 1, ToScale = 1;
    FVector2D FrameOrigin;
    static constexpr float DesktopTileSize = 320;
    float SleepAmount = 0;
    USceneComponent* Joint(FName Name, USceneComponent* Parent, FVector Position);
    UStaticMeshComponent* Part(FName Name, USceneComponent* Parent, FVector Position, FVector Size, FLinearColor Tint, FString Shape = TEXT("Sphere"), bool Glow = false);
    void BuildCharacter();
    void AnimateMesh(float Blink, float Talk);
    void BuildFur();
    void UpdateFur();
    void PoseLeg(int SideIndex, FVector AnkleTarget, FQuat AnkleRotation);
    void BuildAccessories();
    void BuildContactShadow();
    void BuildBed();
    UProceduralMeshComponent* SoftBox(FName Name, USceneComponent* Parent, FVector Position, FVector Size, float Radius, FLinearColor Tint);
    void ReadCommand();
    void PublishFrame();
};

UCLASS()
class AMuseGuardGameMode : public AGameModeBase {
    GENERATED_BODY()
public:
    AMuseGuardGameMode();
    virtual void StartPlay() override;
};
