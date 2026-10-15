"""Read-only dependency preflight for GPU menu presets; never executes a .vpy.

Uses the installed k7sfunc/vsmlrt enums and plugin search path. Successful
preflight is not proof of driver compatibility, initialization or output.
"""
import ast
import contextlib
import io
import json
from pathlib import Path
import sys


def literal(node, assignments):
    if isinstance(node, ast.Name):
        node = assignments.get(node.id, node)
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError):
        return None


def model_paths(tree, mlrt):
    """Resolve literal model arguments, retaining local preset parameter changes."""
    assignments = {target.id: node.value for node in tree.body
                   if isinstance(node, ast.Assign) for target in node.targets
                   if isinstance(target, ast.Name)}
    root = Path(mlrt.models_path)
    paths = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        args = {k.arg: literal(k.value, assignments) for k in node.keywords}
        func = node.func.attr
        model = args.get('model', args.get('model_pth'))
        if func in ('UAI_NV_TRT', 'UAI_DML') and isinstance(model, str):
            paths.append(root / model)
        elif func in ('ARTCNN_NV', 'ArtCNN') and isinstance(model, int):
            paths.append(root / 'ArtCNN' / (mlrt.ArtCNNModel(model).name + '.onnx'))
        elif func in ('RIFE_NV', 'RIFE_DML') and isinstance(model, int):
            name = mlrt.RIFEModel(model).name
            # Upstream enum v4_25_lite corresponds to rife_v4.25_lite.onnx.
            parts = name.split('_')
            name = parts[0] + '.' + parts[1] + ''.join('_' + p for p in parts[2:])
            paths.append(root / 'rife' / ('rife_' + name + '.onnx'))
        elif func in ('DRBA_NV', 'DRBA_DML') and isinstance(model, int):
            name = 'distilDRBA_' + mlrt.DRBAModel(model).name
            if args.get('halfm'):
                name += '_fp16'
            paths.append(root / 'drba' / (name + '.onnx'))
    return list(dict.fromkeys(paths))


def check(preset):
    import vapoursynth as vs
    import k7sfunc  # noqa: F401 - verify the selected portable environment
    from k7sfunc._external import vsmlrt

    tree = ast.parse(preset.read_text(encoding='utf-8-sig'))
    calls = {n.func.attr for n in ast.walk(tree)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
    required = set()
    for call, plugin in {'BILA_NV': 'bilateralgpu_rtc', 'DFTT_NV': 'dfttest2_nvrtc',
                         'BM3D_NV': 'bm3dcuda_rtc', 'UAI_DML': 'ort',
                         'RIFE_DML': 'ort', 'DRBA_DML': 'ort', 'ARTCNN_NV': 'trt',
                         'ArtCNN': 'trt', 'UAI_NV_TRT': 'trt', 'RIFE_NV': 'trt',
                         'DRBA_NV': 'trt'}.items():
        if call in calls:
            required.add(plugin)
    plugins = {p.namespace for p in vs.core.plugins()}
    missing = sorted(required - plugins)
    if missing:
        return dict(ok=False, reason='缺少 VS 插件：' + ', '.join(missing))
    missing_models = [p.name for p in model_paths(tree, vsmlrt) if not p.is_file()]
    if missing_models:
        return dict(ok=False, reason='缺少模型：' + ', '.join(missing_models))
    return dict(ok=True, reason='依赖初检通过；实际初始化由 mpv 检查')


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    try:
        # VS/plugin imports may print diagnostics; keep stdout a single JSON object.
        with contextlib.redirect_stdout(io.StringIO()):
            result = check(Path(sys.argv[1]))
    except Exception as exc:
        result = dict(ok=False, reason='VS 依赖检查失败：' + str(exc))
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
