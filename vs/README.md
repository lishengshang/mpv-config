# VapourSynth 滤镜预设

13 个预设，全部走 GPU 推理，每个是一个独立 `.vpy`，经 `input.conf` 用 `cycle-commands` 按需 toggle。
模板衍生自 [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc)，函数来自 k7sfunc 1.8.1。

纯 CPU 推理的预设（MVTools / QTGMC / CCD）已移至 `archive/vs/`，见文末。

## 命名约定

- **前缀 = 功能**：`MEMC_` 补帧 · `SR_` 超分 · `MIX_` 超分+补帧 · `NR_` 降噪
- **后缀 = 后端**：`_TRT` TensorRT · `_DML` DirectML · `_CUDA` CUDA
- 画质档位不进文件名，写在各 `.vpy` 的选项注释里

后缀标的是**实际后端**，不是 k7sfunc 的函数名。例如 `NR_BM3D_CUDA` 调的是 `k7f.BM3D_NV`（其内部用 `bm3dcuda_rtc`，是 CUDA 而非 TensorRT）。

## 选型表

| 键位 | 文件 | 算法 | 后端 | 倍率 | 什么时候用 |
|---|---|---|---|---|---|
| `$` | `MEMC_RIFE_TRT` | RIFE 4.26 | TRT | — | 通用补帧，动画与真人都行 |
| `%` | `MEMC_DRBA_TRT` | distilDRBA v1 | TRT | — | 动画补帧，对动漫线条比 RIFE 更稳 |
| `@` | `MEMC_RIFE_DML` | RIFE 4.26 | DML | — | 同 `$`，DirectML 后端 |
| `SHARP`(即 `#`) | `MEMC_DRBA_DML` | distilDRBA v1 | DML | — | 同 `%`，DirectML 后端 |
| `&` | `SR_ARTCNN_TRT` | ArtCNN R8F64 | TRT | 2× | 通用超分。色度用 Bilinear 放大 |
| `ALT+&` | `SR_ARTCNN_CHROMA_TRT` | ArtCNN R8F64 + R8F64_Chroma | TRT | 2× | 同上，但色度改用神经网络重建。4:2:0 BT.709 源收益最明显 |
| `*` | `SR_AnimeJaNaiV3_TRT` | AnimeJaNai V3L1 sharp HD | TRT | 2× | 动画超分，锐化取向 |
| `ALT+^` | `SR_AnimeJaNaiV2_TRT` | AnimeJaNai V2L1 | TRT | 2× | 动画超分，V3 之前的版本 |
| `^` | `SR_AnimeJaNaiV2_DML` | AnimeJaNai V2L1 | DML | 2× | 同上，DirectML 后端 |
| `(` | `SR_HFA2k_TRT` | HFA2kCompact | TRT | 2× | 真人影视超分 |
| `)` | `SR_Anime1080Fixer_TRT` | Anime1080Fixer SUC | TRT | **1×** | **不放大**，只修复 1080p 动画的压缩瑕疵 |
| `ALT+_` | `MIX_SR_MEMC_TRT` | ArtCNN R8F64 + RIFE 4.25lite | TRT | 2× + 补帧 | 一次开超分与补帧，两者都取轻量档 |
| `'` | `NR_BM3D_CUDA` | BM3D | CUDA | — | 强降噪，`Nr_Lv=[5,0,0]` |
| `ALT+~` | — | `vf clr` | — | — | 清空所有视频滤镜（与音频侧 `` ALT+` `` 成对） |

空闲键位：`!`、`+`、`/`（原属已归档的 CPU 预设）。

## A/B 对比组

三组可直接对照测试，测完再决定取舍：

- **模型代际**：`ALT+^`(AnimeJaNai V2) ↔ `*`(AnimeJaNai V3 锐化)
- **推理后端**：`$`↔`@`(RIFE)、`%`↔`SHARP`(DRBA)、`ALT+^`↔`^`(AnimeJaNai V2)，TRT 对 DML
- **色度处理**：`&`(Bilinear 色度) ↔ `ALT+&`(神经网络色度重建)

TensorRT 与 DirectML 共用同一批 ONNX 模型文件，所以后端对比不引入模型差异，比的是速度与支持度。

## 模型文件

位于 `vs-plugins/models/`（在 `portable_config` 之外，与 `mpv.exe` 同级），不进版本控制。

| 模型 | 使用者 | 来源 |
|---|---|---|
| `ArtCNN_R8F64.onnx` | `SR_ARTCNN_TRT`、`SR_ARTCNN_CHROMA_TRT`、`MIX_SR_MEMC_TRT` | [Artoriuz/ArtCNN](https://github.com/Artoriuz/ArtCNN) `ONNX/` |
| `ArtCNN_R8F64_Chroma.onnx` | `SR_ARTCNN_CHROMA_TRT` | 同上，3.5MB |
| `ArtCNN_R8F64_DS.onnx`、`ArtCNN_R16F96.onnx` | 备用档（把 `Model` 改成 8 / 6） | 同上 |
| `the_database_AnimeJaNaiV3L1_sharp_HD_x2_fp16_op17.onnx` | `SR_AnimeJaNaiV3_TRT` | [the-database/mpv-AnimeJaNai](https://github.com/the-database/mpv-AnimeJaNai) |
| `the_database_AnimeJaNaiV2L1_x2_fp16_op17.onnx` | `SR_AnimeJaNaiV2_TRT`、`SR_AnimeJaNaiV2_DML` | 同上 |
| `Phhofm_HFA2kCompact_x2_fp16_op17.onnx` | `SR_HFA2k_TRT` | [phhofm/models](https://github.com/phhofm/models) |
| `Zarxrax_Anime1080Fixer_SUC_x1_fp16_op17.onnx` | `SR_Anime1080Fixer_TRT` | Zarxrax (HuggingFace) |
| RIFE 4.26 / 4.25lite、distilDRBA v1 | `MEMC_*`、`MIX_SR_MEMC_TRT` | vs-mlrt 内置，无需单独下载 |

ArtCNN 的模型编号是 vsmlrt 的枚举（`k7sfunc/_external/vsmlrt.py` 的 `ArtCNNModel`）：`6`=R16F96、`7`=R8F64、`8`=R8F64_DS、`9`=R8F64_Chroma、`17`=R8F64_Chroma_DN。上游 ONNX 目录里**没有** R16F96_Chroma，虽然枚举里有 `12`。

`vs-plugins/models/` 里还有一个 `Sirosky_Ani4Kv2_UltraCompact_x2_fp16_op17.onnx`，目前没有任何预设引用，需要时把某个 `UAI_*` 预设的 `Model` 指向它即可。

## 改名对照

本轮把后缀从"混用后端与画质档"统一成"只表后端"：

| 旧名 | 新名 | 说明 |
|---|---|---|
| `MEMC_RIFE_NV` | `MEMC_RIFE_TRT` | 实际是 TensorRT（`_check_plugin("trt")`） |
| `MEMC_DRBA_NV` | `MEMC_DRBA_TRT` | 实际是 `vsmlrt.BackendV2.TRT` |
| `SR_ARTCNN_NV` | `SR_ARTCNN_TRT` | 实际是 `core.trt.Version()` |
| `SR_AnimeJaNaiV3_NV` | `SR_AnimeJaNaiV3_TRT` | 同上 |
| `SR_HFA2k_NV` | `SR_HFA2k_TRT` | 同上 |
| `SR_Anime1080Fixer_NV` | `SR_Anime1080Fixer_TRT` | 同上 |
| `MIX_SR_MEMC_NV` | `MIX_SR_MEMC_TRT` | 同上 |
| `NR_BM3D_NV` | `NR_BM3D_CUDA` | 函数名叫 `BM3D_NV`，但走 `bm3dcuda_rtc`，是 CUDA |
| `MIX_UAI_NV_TRT` | `SR_AnimeJaNaiV2_TRT` | 原名两处不准：`MIX_` 暗示含补帧但实际只调 `UAI_NV_TRT`；模型是 AnimeJaNai |
| `MIX_UAI_DML` | `SR_AnimeJaNaiV2_DML` | 同上 |
| `SR_ARTCNN_CHROMA_NV` | `SR_ARTCNN_CHROMA_TRT` | 本轮新增后即改名 |

`MEMC_RIFE_DML`、`MEMC_DRBA_DML` 原本后缀就正确，未改。

## 已归档（`archive/vs/`）

| 预设 | 归档原因 |
|---|---|
| `MEMC_MVT_CPU`（原 `MEMC_MVT_LQ`） | MVTools 纯 CPU 推理 |
| `ETC_DEINT_CPU`（原 `ETC_DEINT_EX`） | QTGMC 纯 CPU 推理。去隔行改用 mpv 内置 `deinterlace`，键位 `d` |
| `NR_CCD_CPU`（原 `NR_CCD_STD`） | CCD 纯 CPU 推理。降噪改用 `NR_BM3D_CUDA` |
| `MEMC_RIFE_STD` | 依赖 PyTorch 版 vs-rife，内嵌 Python 无 torch |
| `MEMC_SVP_PRO`、`MIX_UVR_MAD` | 早前归档 |

## 依赖与故障排查

- **运行时必须与 `mpv.exe` 同级**：`python314.dll`、`VSScript.dll`、`Lib/`、`vs-coreplugins/`、`vs-plugins/`。mpv 没有任何选项能指定 VSScript 的加载路径（`--help=vapour` 返回 0 项），所以这套东西搬不走。缺了它 13 个预设全部报错，但配置其余部分照常工作。
- **TensorRT 预设首次运行会构建引擎缓存**（写入 `vs-plugins/models/**/*.engine`），慢是正常的；换分辨率或换模型会重建。
- **CUDA 报 `driver version is insufficient`** → NVIDIA 驱动需 ≥ 580.65。
- 驱动更新后跑仓库根目录的 `verify_vs_filters.bat` 做 13 项无头自检。
- `SR_ARTCNN_CHROMA_TRT` 绕开了 `k7sfunc.ARTCNN_NV`（后者把 `model` 限死在 6/7/8，见 `mod_scale.py:98`），直接调 `vsmlrt.ArtCNN`，因为 k7sfunc 1.8.1 不支持 Chroma 模型。上游对 Chroma 模型的约定见 ArtCNN README：用于 4:2:0 BT.709 内容，色度须先经 bilinear 放大。
