"""Offline probe regressions: AST only, no VS/GPU/import dependencies."""
import ast
import enum
from pathlib import Path
from types import SimpleNamespace
import unittest
import sys
import tempfile
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gpu_probe import model_paths, check


class Models(unittest.TestCase):
    def setUp(self):
        self.mlrt = SimpleNamespace(models_path='models',
            ArtCNNModel=enum.IntEnum('ArtCNNModel', {'ArtCNN_R8F64': 7, 'ArtCNN_R8F64_Chroma': 9}),
            RIFEModel=enum.IntEnum('RIFEModel', {'v4_26': 426, 'v4_25_lite': 4251}),
            DRBAModel=enum.IntEnum('DRBAModel', {'v1': 1, 'v2_lite': 2}))

    def resolve(self, code):
        return [str(p).replace('\\', '/') for p in model_paths(ast.parse(code), self.mlrt)]

    def test_user_model_assignment(self):
        self.assertEqual(self.resolve('Model="custom.onnx"\nk7f.UAI_NV_TRT(clip, model_pth=Model)'),
                         ['models/custom.onnx'])

    def test_artcnn_chroma_parameters(self):
        self.assertEqual(self.resolve('Luma_Model=7\nChroma_Model=9\nvsmlrt.ArtCNN(clip, model=Luma_Model)\nvsmlrt.ArtCNN(clip, model=Chroma_Model)'),
                         ['models/ArtCNN/ArtCNN_R8F64.onnx', 'models/ArtCNN/ArtCNN_R8F64_Chroma.onnx'])

    def test_rife_and_drba_models(self):
        self.assertEqual(self.resolve('k7f.RIFE_NV(clip, model=4251)\nk7f.DRBA_NV(clip, model=2, halfm=True)'),
                         ['models/rife/rife_v4.25_lite.onnx', 'models/drba/distilDRBA_v2_lite_fp16.onnx'])

    def test_dynamic_model_not_executed(self):
        self.assertEqual(self.resolve('Model=__import__("invalid_module")\nk7f.UAI_NV_TRT(clip, model_pth=Model)'), [])

    def test_unknown_enum_fails(self):
        with self.assertRaises(ValueError):
            self.resolve('k7f.ARTCNN_NV(clip, model=12345)')

    def test_current_presets_parse(self):
        for p in (Path(__file__).resolve().parents[1] / 'vs').glob('*.vpy'):
            ast.parse(p.read_text(encoding='utf-8-sig'))

    def probe(self, code, plugins):
        modules = {'vapoursynth': SimpleNamespace(core=SimpleNamespace(
            plugins=lambda: [SimpleNamespace(namespace=p) for p in plugins])),
            'k7sfunc': SimpleNamespace(), 'k7sfunc._external': SimpleNamespace(vsmlrt=self.mlrt)}
        with tempfile.TemporaryDirectory() as folder, patch.dict(sys.modules, modules):
            preset = Path(folder) / 'preset.vpy'
            preset.write_text(code, encoding='utf-8')
            return check(preset)

    def test_missing_plugin_hint(self):
        result = self.probe('clip=k7f.BILA_NV(video_in)', [])
        self.assertFalse(result['ok'])
        self.assertIn('bilateralgpu_rtc', result['reason'])

    def test_missing_model_hint_without_executing_preset(self):
        result = self.probe('raise RuntimeError("must not execute")\nclip=k7f.UAI_NV_TRT(video_in, model_pth="UX_missing_model.onnx")', ['trt'])
        self.assertFalse(result['ok'])
        self.assertIn('UX_missing_model.onnx', result['reason'])


if __name__ == '__main__':
    unittest.main()
