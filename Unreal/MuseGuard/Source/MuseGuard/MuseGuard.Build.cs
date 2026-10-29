using UnrealBuildTool;
public class MuseGuard : ModuleRules {
    public MuseGuard(ReadOnlyTargetRules Target) : base(Target) {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new string[] { "Core", "CoreUObject", "Engine", "InputCore", "RenderCore", "RHI", "Json", "ProceduralMeshComponent" });
    }
}
