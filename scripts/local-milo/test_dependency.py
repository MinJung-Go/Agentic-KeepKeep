import pathlib
import tempfile
import unittest
from dependency import inference_dependency


class DependencyTests(unittest.TestCase):
    def read(self, fields):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'project.yml'
            path.write_text('packages:\n  MiloInference:\n' + fields + '\nsettings:\n')
            return inference_dependency(path)

    def test_current_project_uses_full_remote_pin(self):
        pin = inference_dependency()
        self.assertEqual(pin['url'], 'https://github.com/MinJung-Go/MiloInference.git')
        self.assertEqual(len(pin['revision']), 40)

    def test_floating_or_missing_revision_is_rejected(self):
        for revision in ['main', 'v0.1.0', '5c94a02', '']:
            with self.assertRaises(ValueError):
                self.read('    url: https://github.com/MinJung-Go/MiloInference.git\n    revision: ' + revision + '\n')

    def test_wrong_repo_and_local_override_are_rejected(self):
        revision = '5c94a02bf00d68a1bb3f5a7b2a104bbedd977888'
        with self.assertRaises(ValueError):
            self.read('    url: https://example.com/other.git\n    revision: ' + revision + '\n')
        with self.assertRaises(ValueError):
            self.read('    url: https://github.com/MinJung-Go/MiloInference.git\n    revision: ' + revision + '\n    path: Packages/MiloInference\n')


if __name__ == '__main__':
    unittest.main()
