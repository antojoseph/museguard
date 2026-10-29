#!/usr/bin/env bash
set -euo pipefail
MUSE_MODEL_HOME="${MUSE_MODEL_HOME:-$HOME/Library/Application Support/MuseGuard/LocalModel}"
mkdir -p "$MUSE_MODEL_HOME"
chmod 700 "$MUSE_MODEL_HOME"
python3 - "$MUSE_MODEL_HOME" <<'PY'
import hashlib,json,pathlib,secrets,sys,tarfile,urllib.request
root=pathlib.Path(sys.argv[1]);tag='b11946'
runtime=root/'runtime'
if not (runtime/'llama-server').exists():
    with urllib.request.urlopen('https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/'+tag) as r: release=json.load(r)
    asset=next(a for a in release['assets'] if a['name']==f'llama-{tag}-bin-macos-arm64.tar.gz')
    archive=root/asset['name']
    print('Downloading Apple Silicon llama.cpp '+tag,flush=True)
    urllib.request.urlretrieve(asset['browser_download_url'],archive)
    digest=asset.get('digest')
    if digest and digest.startswith('sha256:'):
        assert hashlib.sha256(archive.read_bytes()).hexdigest()==digest.split(':',1)[1], 'Runtime checksum mismatch'
    unpack=root/'unpack';unpack.mkdir(exist_ok=True)
    with tarfile.open(archive) as tar:
        for entry in tar.getmembers():
            assert not pathlib.PurePosixPath(entry.name).is_absolute() and '..' not in pathlib.PurePosixPath(entry.name).parts
        tar.extractall(unpack)
    binary=next(unpack.rglob('llama-server'))
    import shutil
    shutil.copytree(binary.parent,runtime,dirs_exist_ok=True)
    archive.unlink()
key=root/'api-key'
if not key.exists():key.write_text(secrets.token_urlsafe(32))
key.chmod(0o600)
(root/'manifest.json').write_text(json.dumps({'runtime':tag,'repository':'meta-models/Muse-Glimmer-30B-GGUF','revision':'b44f1072cf75e918a1b82a3a17b45c4389b076e7','model':'Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf','vision':'mmproj-Muse-Glimmer-30B-Q4_K_M.gguf'},indent=2))
PY
hf download meta-models/Muse-Glimmer-30B-GGUF --revision b44f1072cf75e918a1b82a3a17b45c4389b076e7 --local-dir "$MUSE_MODEL_HOME/weights" --include 'Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf' --include 'mmproj-Muse-Glimmer-30B-Q4_K_M.gguf'
echo 'Muse Glimmer and its vision projector are installed locally.'
