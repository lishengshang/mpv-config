# VapourSynth 预设

15 个独立 `.vpy`，核心滤镜走 GPU；命名为功能前缀 `MEMC_` / `SR_` / `MIX_` / `NR_` 加实际后端 `_TRT` / `_DML` / `_CUDA`。参数保留在各预设中，改名须同步键位与验证入口。

菜单、状态恢复、部署与自检统一见 [GPU 指南](../docs/gpu-setup.md)。`.vpy` 不包含运行时/模型；RTX 集合为 12 个 TRT/CUDA，另有三个 DML 对照预设。来源：[mpv_PlayKit / k7sfunc](https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc)，历史验证 k7sfunc 1.8.1。

## 预设与键位

| 键位 | 文件（省略 `.vpy`） | 模型/算法 | 后端 | 模型倍率/用途 |
| --- | --- | --- | --- | --- |
| `$` | `MEMC_RIFE_TRT` | RIFE 4.26 | TRT | 补帧 |
| `%` | `MEMC_DRBA_TRT` | distilDRBA v1 | TRT | 动画补帧候选 |
| `@` | `MEMC_RIFE_DML` | RIFE 4.26 | DML | 补帧后端对照 |
| `SHARP`（`#`） | `MEMC_DRBA_DML` | distilDRBA v1 | DML | 补帧后端对照 |
| `&` | `SR_ARTCNN_TRT` | ArtCNN R8F64 | TRT | 2×，bilinear 色度 |
| `ALT+&` | `SR_ARTCNN_CHROMA_TRT` | R8F64 + Chroma | TRT | 2×，4:2:0 BT.709 色度重建 |
| `*` | `SR_AnimeJaNaiV3_TRT` | V3L1 sharp HD | TRT | 2×，动画锐化取向 |
| `ALT+^` | `SR_AnimeJaNaiV2_TRT` | V2L1 | TRT | 2×，动画 |
| `^` | `SR_AnimeJaNaiV2_DML` | V2L1 | DML | 2×，后端对照 |
| `(` | `SR_HFA2k_TRT` | HFA2kCompact | TRT | 2×，真人候选 |
| `)` | `SR_Anime1080Fixer_TRT` | Anime1080Fixer SUC | TRT | 1×，修复而非放大 |
| `ALT+_` | `MIX_SR_MEMC_TRT` | R8F64 + RIFE 4.25lite | TRT | 超分+补帧 |
| `'` | `NR_BM3D_CUDA` | BM3D | CUDA | `Nr_Lv=[5,0,0]` |
| `!` | `NR_BILATERAL_CUDA` | Bilateral | CUDA | `k7f.BILA_NV`，无需 ONNX |
| `+` | `NR_DFTTEST_CUDA` | DFTTest2 | CUDA/NVRTC | `k7f.DFTT_NV`，无需 ONNX |

TRT/DML 对照共用模型；倍率是模型倍率，实际尺寸受 `H_Pre` / `H_Max` 等个人参数影响。未凭模型名称宣称主观效果或实时速度。CPU 预设位于 `archive/vs/`，默认不启用；去隔行可用 mpv 内置 `d`。

## 模型对应

模型位于 mpv 同级 `vs-plugins/models/`，不进 Git；ArtCNN 放 `ArtCNN/` 子目录，自定义 UAI 放根部。

| 文件 | 使用者 | 来源 |
| --- | --- | --- |
| `ArtCNN/ArtCNN_R8F64.onnx` | ArtCNN、Chroma、MIX | [Artoriuz/ArtCNN](https://github.com/Artoriuz/ArtCNN) `ONNX/` |
| `ArtCNN/ArtCNN_R8F64_Chroma.onnx` | Chroma | 同上 |
| `the_database_AnimeJaNaiV3L1_sharp_HD_x2_fp16_op17.onnx` | AnimeJaNai V3 | [mpv-AnimeJaNai](https://github.com/the-database/mpv-AnimeJaNai) |
| `the_database_AnimeJaNaiV2L1_x2_fp16_op17.onnx` | AnimeJaNai V2 TRT/DML | 同上 |
| `Phhofm_HFA2kCompact_x2_fp16_op17.onnx` | HFA2k | [phhofm/models](https://github.com/phhofm/models) |
| `Zarxrax_Anime1080Fixer_SUC_x1_fp16_op17.onnx` | Anime1080Fixer | Zarxrax（Hugging Face） |
| RIFE 4.26 / 4.25lite、distilDRBA v1 | MEMC、MIX | 匹配的 vs-mlrt 模型包 |

当前 vsmlrt ArtCNN 枚举：6=R16F96、7=R8F64、8=R8F64_DS、9=R8F64_Chroma、17=R8F64_Chroma_DN。切模型前核对安装版本与实际模型文件，不仅修改编号。

## 维护注意

- `NR_BM3D_CUDA` 调用的函数名虽为 `BM3D_NV`，实际插件是 `bm3dcuda_rtc`；文件后缀按后端命名。
- Chroma 预设直接调 `vsmlrt.ArtCNN`，因为 k7sfunc 1.8.1 的 `ARTCNN_NV` 仅接受 6/7/8；4:2:0 BT.709 色度先 bilinear 放大，不在更新时改回普通 ArtCNN 调用。
- 首次 TRT 构建及换尺寸/模型可能较慢；缺模型、DLL 不匹配和驱动不足均需实际产帧检查，不能只看导入成功。
- 驱动/运行时更新后执行 `tools/verify-gpu.ps1 -Run`；仓库外旧检查批处理仅作辅助。已知 DRBA 暂停长序列问题见 [项目状态](../PROJECT_STATE.md)。
