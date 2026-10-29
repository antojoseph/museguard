using UnrealBuildTool;
public class MuseGuardEditorTarget : TargetRules {
    public MuseGuardEditorTarget(TargetInfo Target) : base(Target) {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
        ExtraModuleNames.Add("MuseGuard");
    }
}
