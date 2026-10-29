using UnrealBuildTool;
public class MuseGuardTarget : TargetRules {
    public MuseGuardTarget(TargetInfo Target) : base(Target) {
        Type = TargetType.Game;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
        ExtraModuleNames.Add("MuseGuard");
    }
}
