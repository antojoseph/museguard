#!/usr/bin/env python3
"""Refresh the deliverable manifest after intentionally saving a new checkpoint."""

from datetime import datetime, timezone
import json
from pathlib import Path
from resume import digest

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'outputs/resume/assets-manifest.json'

files = []
for path in sorted((ROOT / 'outputs').rglob('*')):
    if not path.is_file() or path == TARGET or path.name == '.DS_Store':
        continue
    if path.suffix in {'.blend1', '.blend2'}:
        continue
    files.append({'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
                  'sha256': digest(path)})
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text(json.dumps({'created_utc': datetime.now(timezone.utc).isoformat(),
                             'algorithm': 'SHA-256', 'files': files}, indent=2) + '\n')
print('Manifest saved for {} deliverables.'.format(len(files)))
