#!/usr/bin/env python3
"""Validate a survey and prepare overlapping, portable Atlas image batches.

No API calls, uploads, rescaling, pose estimation or generated ground truth.
"""
import argparse
import json
import math
from pathlib import Path
import shutil


def records(path):
    with path.open() as stream:
        for number, line in enumerate(stream, 1):
            try:
                yield json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path.name}:{number}: incomplete JSON; preserve original and recover separately") from error


def asset(root, name):
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"Missing or unsafe asset: {name}")
    return path


def prepare(root, output, batch_size=16, overlap=4, spacing=1.0):
    if not 0 <= overlap < batch_size or batch_size < 2 or spacing <= 0:
        raise ValueError("Require batch size >= 2, 0 <= overlap < batch size, spacing > 0")
    root, output = Path(root).resolve(), Path(output).resolve()
    if output == root or root.is_relative_to(output) or output.is_relative_to(root):
        raise ValueError("Output must be separate from the source survey")
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('schema') != 'parking-survey/1':
        raise ValueError('Expected parking-survey/1')
    if manifest.get('state') != 'complete':
        raise ValueError('Survey not complete; inspect failed/interrupted/crash captures before using')
    selected, previous = [], -math.inf
    sampled = 0
    for frame in records(root / 'frames.jsonl'):
        if not frame.get('rgb'):
            continue
        sampled += 1
        image = asset(root, frame['rgb'])
        camera = frame['camera']
        intrinsics = camera['intrinsics']
        extrinsics = camera['extrinsics']
        numeric = [intrinsics[k] for k in ('fx', 'fy', 'cx', 'cy', 'width', 'height')]
        numeric += extrinsics['position'] + extrinsics['quaternion'] + frame['transform']
        if not all(isinstance(v, (float, int)) and math.isfinite(v) for v in numeric):
            raise ValueError('Non-finite camera calibration')
        if intrinsics['fx'] <= 0 or intrinsics['fy'] <= 0 or extrinsics['coordinateSystem'] != 'rub':
            raise ValueError('Invalid intrinsics or camera axes')
        if len(frame['transform']) != 16 or len(extrinsics['quaternion']) != 4 or len(extrinsics['position']) != 3:
            raise ValueError('Invalid camera dimensions')
        if abs(sum(x*x for x in extrinsics['quaternion']) - 1) > 0.01:
            raise ValueError('Camera quaternion must be unit length')
        depth = frame.get('depth')
        if depth:
            pixels = depth['width'] * depth['height']
            if asset(root, depth['file']).stat().st_size != pixels * 4:
                raise ValueError(f"Wrong depth byte count: {depth['file']}")
            if depth.get('confidence') and asset(root, depth['confidence']).stat().st_size != pixels:
                raise ValueError('Wrong confidence byte count')
        if frame['tracking'] != 'normal' or frame['timestamp'] - previous < spacing:
            continue
        previous = frame['timestamp']
        selected.append((frame, image))
    if sampled != manifest['samples']:
        raise ValueError('Manifest sample count differs from frames log')
    if len(selected) < 2:
        raise ValueError('Need at least two usable RGB frames')
    # Refuse reuse so stale files can never silently enter a batch.
    output.mkdir(parents=True, exist_ok=False)
    batches = []
    for start in range(0, len(selected), batch_size - overlap):
        chunk = selected[start:start + batch_size]
        if len(chunk) < 2:
            break
        folder = output / f'batch-{len(batches):03d}'
        folder.mkdir()
        frames = []
        for frame, image in chunk:
            shutil.copy2(image, folder / image.name)
            frames.append({'file': image.name, 'timestamp': frame['timestamp'], 'camera': frame['camera']})
        (folder / 'cameras.json').write_text(json.dumps(frames, indent=2) + '\n')
        batches.append({'folder': folder.name, 'frames': len(chunk)})
        if start + batch_size >= len(selected):
            break
    gps = list(records(root / 'locations.jsonl'))
    (output / 'handoff.json').write_text(json.dumps({
        'schema': 'parking-survey-handoff/1', 'source': root.name,
        'site': manifest['site'], 'environment': manifest['environment'], 'level': manifest['level'],
        'batches': batches, 'sampledImages': sampled, 'selectedImages': len(selected),
        'gpsFixes': len(gps), 'georeference': manifest['georeference'],
        'reviewRequired': ['Inspect sharpness, overlap and moving vehicles/people before upload.',
                           'Batches share raw ARKit poses but Atlas reconstruction outputs need alignment.',
                           'Camera metadata is for posed workflows; images2PosedRGBD accepts images without cameras.',
                           'Use measured geometry and surveyed alignment to validate simulation dimensions.',
                           'GPS does not establish an accurate satellite-to-AR transform.'],
    }, indent=2) + '\n')
    return batches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('survey', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--batch-size', type=int, default=16)
    parser.add_argument('--overlap', type=int, default=4)
    parser.add_argument('--spacing', type=float, default=1.0, help='Minimum time between selected images (seconds)')
    args = parser.parse_args()
    try:
        batches = prepare(args.survey, args.output, args.batch_size, args.overlap, args.spacing)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'Cannot prepare survey: {error}\n')
    print(f'Prepared {len(batches)} batches in {args.output}. Inspect images before uploading.')


if __name__ == '__main__':
    main()
