#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSE_ENGINE="${MUSE_UNREAL_ROOT:-/Users/Shared/Epic Games/UE_5.8}"
MUSE_SOURCE="${MUSE_AVATAR_SOURCE:-$MUSE_ROOT/Unreal/MuseGuard}"
MUSE_PACKAGE_PROJECT="$HOME/Library/Application Support/MuseGuard/RendererPackaging"
MUSE_PACKAGE_OUTPUT="$MUSE_ROOT/build/PackagedRenderer"
mkdir -p "$MUSE_PACKAGE_PROJECT" "$MUSE_PACKAGE_OUTPUT" "$MUSE_ROOT/build"
[[ -x "$MUSE_ENGINE/Engine/Build/BatchFiles/RunUAT.sh" ]] || { echo 'Unreal is required on the build machine to package the renderer.' >&2; exit 1; }
[[ -f "$MUSE_SOURCE/MuseGuard.uproject" ]] || { echo 'Renderer project is missing.' >&2; exit 1; }

MUSE_RENDERER_HASH="$(python3 - "$MUSE_SOURCE" "$MUSE_ENGINE" "${BASH_SOURCE[0]}" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); digest=hashlib.sha256()
for directory in ['Source','Content','Config','Scripts']:
    for path in sorted((root/directory).rglob('*')):
        if path.is_file(): digest.update(str(path.relative_to(root)).encode());digest.update(path.read_bytes())
digest.update((root/'MuseGuard.uproject').read_bytes())
digest.update(pathlib.Path(sys.argv[2],'Engine/Build/Build.version').read_bytes())
digest.update(pathlib.Path(sys.argv[3]).read_bytes())
digest.update(b'arm64-shipping-package-v2')
print(digest.hexdigest())
PY
)"
if [[ "${MUSE_REBUILD_RENDERER:-0}" != 1 && -f "$MUSE_PACKAGE_OUTPUT/source.sha256" && -d "$MUSE_PACKAGE_OUTPUT/MuseRenderer.app" && "$(cat "$MUSE_PACKAGE_OUTPUT/source.sha256")" == "$MUSE_RENDERER_HASH" ]]; then
  echo 'Using the current standalone renderer package.'
  exit 0
fi
for item in Source Content Config Scripts; do
  mkdir -p "$MUSE_PACKAGE_PROJECT/$item"
  rsync -a --delete "$MUSE_SOURCE/$item/" "$MUSE_PACKAGE_PROJECT/$item/"
done
cp "$MUSE_SOURCE/MuseGuard.uproject" "$MUSE_PACKAGE_PROJECT/MuseGuard.uproject"
cat >> "$MUSE_PACKAGE_PROJECT/Config/DefaultGame.ini" <<'EOF'

[/Script/UnrealEd.ProjectPackagingSettings]
BuildConfiguration=PPBC_Shipping
bUsePakFile=True
bUseIoStore=False
bUseZenStore=False
bShareMaterialShaderCode=True
+MapsToCook=(FilePath="/Game/Maps/MuseStage")
+DirectoriesToAlwaysCook=(Path="/Game/Muse")
+DirectoriesToAlwaysCook=(Path="/Engine/BasicShapes")
EOF
cat >> "$MUSE_PACKAGE_PROJECT/Config/DefaultEngine.ini" <<'EOF'

[/Script/MacTargetPlatform.MacTargetSettings]
TargetArchitecture=MacTargetArchitectureAppleSilicon
EditorTargetArchitecture=MacTargetArchitectureAppleSilicon
EOF
"$MUSE_ENGINE/Engine/Build/BatchFiles/Mac/Build.sh" MuseGuardEditor Mac Development "$MUSE_PACKAGE_PROJECT/MuseGuard.uproject" -waitmutex -NoHotReload -architecture=arm64 > "$MUSE_ROOT/build/packaged-renderer-editor-build.log" 2>&1 || {
  tail -60 "$MUSE_ROOT/build/packaged-renderer-editor-build.log" >&2; exit 1;
}
"$MUSE_ENGINE/Engine/Build/BatchFiles/RunUAT.sh" BuildCookRun \
  -project="$MUSE_PACKAGE_PROJECT/MuseGuard.uproject" -noP4 -unattended -utf8output \
  -platform=Mac -targetplatform=Mac -architecture=arm64 -clientconfig=Shipping \
  -build -cook -map=/Game/Maps/MuseStage -stage -pak -package -archive \
  -archivedirectory="$MUSE_PACKAGE_OUTPUT/Archive" -nodebuginfo -nosign \
  > "$MUSE_ROOT/build/packaged-renderer-cook.log" 2>&1 || {
  tail -80 "$MUSE_ROOT/build/packaged-renderer-cook.log" >&2; exit 1;
}
python3 - "$MUSE_PACKAGE_PROJECT" "$MUSE_PACKAGE_OUTPUT" <<'PY'
import pathlib,plistlib,shutil,sys
project,out=map(pathlib.Path,sys.argv[1:])
apps=[p for p in (out/'Archive').rglob('*.app') if (p/'Contents/Info.plist').is_file() and 'CrashReport' not in p.name]
apps=[p for p in apps if not any(parent.suffix=='.app' for parent in p.parents)]
if len(apps)!=1:raise SystemExit(f'Expected one packaged renderer app; found {len(apps)}')
target=out/'MuseRenderer.app'
if target.exists():shutil.rmtree(target)
shutil.copytree(apps[0],target,symlinks=True)
info=plistlib.loads((target/'Contents/Info.plist').read_bytes())
executable=target/'Contents/MacOS'/info['CFBundleExecutable']
if not executable.is_file():raise SystemExit('Packaged renderer executable missing')
pak_dirs=[p for p in target.rglob('Content/Paks') if 'MuseGuard' in p.parts]
if len(pak_dirs)!=1:raise SystemExit(f'Expected one packaged project Content/Paks directory; found {len(pak_dirs)}')
content=pak_dirs[0].parent
# Runtime data is deliberately loose NonUFS data. Do not copy uncooked uassets
# over cooked packages, and retain the community attribution beside the data.
data_dir=content/'Muse';data_dir.mkdir(parents=True,exist_ok=True)
for pattern in ['*.json','*.musemesh','*.txt']:
    for source in (project/'Content/Muse').glob(pattern):shutil.copy2(source,data_dir/source.name)
for filename in ['Jolly.musemesh','Jolly.json','GuardAccessories.json','RoundGlasses.json','ATTRIBUTION.txt','ROUND_GLASSES_ATTRIBUTION.txt']:
    if not (data_dir/filename).is_file():raise SystemExit('Missing required renderer data: '+filename)
config=content.parent/'Config';config.mkdir(parents=True,exist_ok=True)
shutil.copy2(project/'Config/MuseAccessories.json',config/'MuseAccessories.json')
info['LSUIElement']=True
info['CFBundleIdentifier']='com.museguard.renderer'
info['CFBundleName']='Muse Renderer'
(target/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
print('Packaged standalone renderer:',target)
PY
MUSE_RENDERER_IDENTITY="${MUSE_CODESIGN_IDENTITY:-}"
if [[ -z "$MUSE_RENDERER_IDENTITY" ]]; then
  MUSE_RENDERER_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi
MUSE_RENDERER_IDENTITY="${MUSE_RENDERER_IDENTITY:--}"
python3 - "$MUSE_PACKAGE_OUTPUT/MuseRenderer.app" "$MUSE_RENDERER_IDENTITY" <<'PY'
import pathlib,re,subprocess,sys
app=pathlib.Path(sys.argv[1]).resolve();identity=sys.argv[2]
info=__import__('plistlib').loads((app/'Contents/Info.plist').read_bytes())
main=app/'Contents/MacOS'/info['CFBundleExecutable']
magics={bytes.fromhex(value) for value in ['cffaedfe','feedfacf','cafebabe','bebafeca','cafebabf','bfbafeca']}
binaries=[]
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():continue
    with path.open('rb') as handle:magic=handle.read(4)
    if magic in magics:binaries.append(path)
for path in binaries:
    output=subprocess.check_output(['otool','-l',str(path)],text=True)
    # UAT retains fallback build-machine RPATHs. Remove any search directory
    # outside this helper so a missing library cannot load from an installation.
    rpaths=set(re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)',output))
    for rpath in rpaths:
        resolved=rpath.replace('@loader_path',str(path.parent)).replace('@executable_path',str(main.parent))
        if resolved.startswith('@') or not pathlib.Path(resolved).resolve().is_relative_to(app):
            subprocess.run(['install_name_tool','-delete_rpath',rpath,str(path)],check=True)
# Sign code inside-out. --deep does not replace loose third-party dylib
# signatures reliably; a differently signed TBB library prevents launch.
# Ad-hoc source builds omit hardened runtime because they have no Team ID.
options=['--options','runtime'] if identity!='-' else []
for path in sorted(binaries,key=lambda value:len(value.parts),reverse=True):
    subprocess.run(['codesign','--force',*options,'--timestamp=none','--sign',identity,str(path)],check=True)
subprocess.run(['codesign','--force',*options,'--timestamp=none','--sign',identity,str(app)],check=True)
PY
codesign --verify --deep --strict "$MUSE_PACKAGE_OUTPUT/MuseRenderer.app"
printf '%s\n' "$MUSE_RENDERER_HASH" > "$MUSE_PACKAGE_OUTPUT/source.sha256"
