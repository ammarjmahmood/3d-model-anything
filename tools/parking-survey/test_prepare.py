import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SurveyPreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'survey'
        self.root.mkdir()
        (self.root / 'rgb').mkdir()
        self.manifest = {'schema': 'parking-survey/1', 'state': 'complete', 'samples': 20,
                         'site': 'Test lot', 'environment': 'Outdoor parking lot', 'level': 'Ground',
                         'georeference': {'status': 'unaligned'}}
        self.frames = []
        for i in range(20):
            name = f'rgb/{i:06}.jpg'
            (self.root / name).write_bytes(b'fixture-image')
            self.frames.append({'rgb': name, 'tracking': 'normal', 'timestamp': float(i),
                'transform': [1,0,0,0,0,1,0,0,0,0,1,0,float(i),0,0,1],
                'camera': {'intrinsics': {'fx': 10, 'fy': 10, 'cx': 5, 'cy': 5, 'width': 10, 'height': 10},
                           'extrinsics': {'position': [float(i),0,0], 'quaternion': [0,0,0,1], 'coordinateSystem': 'rub'}}})
        self.save()
        (self.root / 'locations.jsonl').write_text('')
        self.output = Path(self.tmp.name) / 'atlas'

    def save(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        (self.root / 'frames.jsonl').write_text(''.join(json.dumps(f) + '\n' for f in self.frames))

    def test_overlap_and_calibration_are_preserved(self):
        batches = module.prepare(self.root, self.output)
        self.assertEqual([b['frames'] for b in batches], [16, 8])
        a = json.loads((self.output / 'batch-000/cameras.json').read_text())
        b = json.loads((self.output / 'batch-001/cameras.json').read_text())
        self.assertEqual(a[-4:], b[:4])
        self.assertEqual(a[0]['camera'], self.frames[0]['camera'])

    def test_rejects_unfinished_capture(self):
        self.manifest['state'] = 'recording'; self.save()
        with self.assertRaises(ValueError): module.prepare(self.root, self.output)

    def test_rejects_missing_or_external_asset(self):
        self.frames[0]['rgb'] = '../outside.jpg'; self.save()
        with self.assertRaises(ValueError): module.prepare(self.root, self.output)

    def test_rejects_wrong_depth_size(self):
        (self.root / 'depth.f32').write_bytes(b'bad')
        self.frames[0]['depth'] = {'file': 'depth.f32', 'width': 2, 'height': 2}; self.save()
        with self.assertRaises(ValueError): module.prepare(self.root, self.output)

    def test_rejects_stale_output(self):
        self.output.mkdir()
        with self.assertRaises(FileExistsError): module.prepare(self.root, self.output)

    def test_rejects_manifest_mismatch(self):
        self.manifest['samples'] = 21; self.save()
        with self.assertRaises(ValueError): module.prepare(self.root, self.output)


if __name__ == '__main__': unittest.main()
