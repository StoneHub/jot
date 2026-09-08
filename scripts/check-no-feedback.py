#!/usr/bin/env python3
"""Reject UI feedback integration in source and, optionally, a built app bundle."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
markers = (b'DevFeedback', b'feedbackTarget', b'feedbackOverlay', b'feedbackViewport', b'FeedbackCommands')
files = list((root / 'Sources').rglob('*.swift')) + [root / 'project.yml', root / 'Jot.xcodeproj/project.pbxproj']
for path in files:
    if any(marker in path.read_bytes() for marker in markers):
        raise SystemExit(f'Feedback integration remains: {path.relative_to(root)}')
vendored = subprocess.check_output(['git', '-C', str(root), 'ls-files', 'Vendor/DevFeedback'], text=True)
if vendored.strip():
    raise SystemExit('Vendored feedback files remain tracked.')
if len(sys.argv) > 1:
    app = Path(sys.argv[1])
    if not (app / 'Contents/MacOS/Jot').is_file():
        raise SystemExit('Expected a built Jot.app bundle.')
    binary_markers = markers + (b'FeedbackPanel', b'FeedbackSession', b'FeedbackHistory', b'dev-feedback.note', b'UI Feedback')
    for path in app.rglob('*'):
        if 'DevFeedback' in path.name:
            raise SystemExit(f'Feedback artifact remains: {path}')
        if not path.is_file():
            continue
        data = path.read_bytes()
        if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf'):
            if any(marker in data for marker in binary_markers):
                raise SystemExit(f'Feedback runtime or metadata remains: {path}')
print('Feedback removal checks passed.')
