# 新电脑安装与 GPU 滤镜

本配置面向 Windows NVIDIA RTX，默认取舍为实时播放优先，重画质按需开启。所有新增效果的核心计算使用 GPU；VS 图像格式转换、帧调度等仍可能使用 CPU。

## 先获得可用的轻量超分

1. 安装支持 `gpu-next` 的 64 位 Windows mpv，将本仓库放到 `mpv.exe` 同级的 `portable_config/`。
2. 更新 NVIDIA 驱动，在双显卡笔记本的 Windows 图形设置里将 mpv 选为高性能 GPU。
3. 打开 SDR 动画，把窗口放大或全屏。按 `CTRL+ALT+1` 使用 ArtCNN C4F16；性能足够时按 `CTRL+ALT+2` 使用 C4F32。`CTRL+0` 清空着色器。

这两个 shader 已随配置提供，不需要 Python、VS、ONNX 模型或 TensorRT。选择时替换当前 shader 列表，避免叠加多个超分；不会清空 VS 滤镜，切换路线前可按 `ALT+~` 清空 VS。

维护者可运行 `tools/export-config.ps1` 导出 `cache/packages/mpv-portable-config.zip`；使用 Git 选取已跟踪和未忽略文件，并排除 `local.conf`、缓存与私人记录。配置 ZIP 解压到 `mpv.exe` 同级后会生成 `portable_config/`。构建工具需要 Git 与 7-Zip，接收者解压使用不需要 Git。

**VS 是可选增强包**，基础配置不要求下载它。尚未安装时不要启用视频滤镜菜单里的 VS 预设；安装后再开启这些功能。

## 将这台电脑的可用 VS 做成可选压缩包

已有验证过的运行时，可以直接复用打包，不必在新电脑重新拼依赖。在本机 `portable_config` 下执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/export-vs-addon.ps1
```

工具使用现有的 7-Zip，将便携 Python/VS、插件与现有模型导出到 `cache/packages/mpv-VS-RTX-addon.7z`，附 SHA256 并检查压缩包完整性。不会包含本项目配置、私人路径/token、播放记录或 TensorRT 引擎缓存。它打包的是本机组件，不是自动下载的最新版；用户实际分享前应核对各上游许可。

新电脑只需：**安装 mpv → 放入 portable_config → 想用 VS 时把增强包解压到 mpv.exe 同级 → 双击 `portable_config/tools/verify-gpu.cmd`**。解压后应直接看到 `python.exe`、`VSScript.dll`、`vs-plugins/`，不要多套一层 `mpv-VS-RTX-addon/`。新目录安装，不与另一版 VS 混用。

ArtCNN 的 C 系列由上游定位为实时播放；C4F16 是轻量档，C4F32 是更大的模型。shader 只有在目标宽高都超过源尺寸 1.3 倍时才触发，原尺寸显示看不到变化属于正常。适用重点为 SDR 动画，不宣称真人、HDR 或所有内容都变好。

## 为什么只复制配置不能使用 VS

`.vpy` 是调用脚本，不包含 Python、VS 动态库、CUDA/TensorRT 运行库和模型。仅安装 mpv 并复制 `portable_config` 时，上面的 shader 路线可以使用，但 VS 补帧、VS 超分和 CUDA 降噪还需要外部运行时。

优先复用 [hooke007 的部署方式](https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc#1-使用引导)，不要另装多套混杂的 Python/VS。两个上游安装选项：

- **省心路线**：[mpv_PlayKit Releases](https://github.com/hooke007/mpv_PlayKit/releases)，选择 NVIDIA 的 `vsNV` 组件包。2026-10-14 核对到 `20260510` 版，两段压缩包合计约 2.7GB。下载全部分卷，使用 7-Zip 从 `.001` 解压到临时目录，按包内目录取 Python/VS、插件与模型运行时；本项目 `portable_config` 保留，不覆盖为上游配置。先在空目录试部署，避免混用不同版 DLL。
- **按需路线**：[便携 Python + VS 快速部署包](https://github.com/hooke007/dotfiles/releases/tag/mpv_addones) 解压到 mpv 同级，再安装 k7sfunc、[vs-mlrt](https://github.com/AmusementClub/vs-mlrt) 与使用到的 GPU 插件和模型。组件更多，适合愿意维护依赖的用户。

省心路线可用本项目的导入工具：将上游包解压到独立临时目录，双击 `tools/install-vs-runtime.cmd`，输入解压目录。工具自动寻找唯一的 Python/VS 根目录，仅复制运行时组件，不复制上游 `portable_config` 或 `mpv.exe`。目标目录应只有基础 mpv 与本项目配置；已有 VS 的目录会拒绝导入，避免混合版本。导入后双击 `tools/verify-gpu.cmd` 验证。

可先在终端预览复制清单：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/install-vs-runtime.ps1 -Source "C:\Downloads\vsNV-extracted" -WhatIf
```

导入工具不会自动下载模型或重建算法：上游包未附带的自定义模型仍需按下表补充；只想补帧和 CUDA 降噪时，不需要为未使用的超分模型额外下载。导入结束的基础检查只证明 Python/VS/k7sfunc 能导入，GPU 是否可用以自检产帧为准。

快速部署包核对到 `py.3_14_3+vs.R73-portable.7z`，约 19.3MiB；这只是 Python+VS 基础，并不等于完整 GPU 滤镜包。下载资产会变化，应以对应发行页为准。不要只取一个 `VSScript.dll`，整套匹配的 Python、VS 和附属文件都要保留。

按需安装 k7sfunc 时，在 mpv 同级运行：

```powershell
.\python.exe -m pip install "k7sfunc==1.8.1"
```

1.8.1 是本轮验证版本，不默认 `-U` 升级所有依赖；首次部署缺 pip 时按部署包与上游指引处理。完整 vsNV 包已有匹配的依赖时先检查，再决定是否安装，避免覆盖它的组件。

## 目录与模型

以下是关键位置示意，并非运行时文件的完整清单；部署包内所有附属 DLL、`.pyd`、zip、配置文件也需保留。

```text
mpv/
  mpv.exe, mpv.com
  python.exe, python3.dll, python314.dll, python314._pth, python314.zip
  VSScript.dll, portable.vs
  Lib/site-packages/k7sfunc/
  vs-coreplugins/
  vs-plugins/
    vstrt.dll, akarin.dll
    vsmlrt-cuda/                 # TensorRT / CUDA runtime and trtexec
    bilateralgpu_rtc.dll         # new Bilateral denoise
    dfttest2_nvrtc.dll           # new DFTTest denoise
    bm3dcuda_rtc.dll
    models/
      rife/, drba/              # models from matching vs-mlrt package
      ArtCNN/
        ArtCNN_R8F64.onnx
        ArtCNN_R8F64_Chroma.onnx
      the_database_AnimeJaNaiV2L1_x2_fp16_op17.onnx
      the_database_AnimeJaNaiV3L1_sharp_HD_x2_fp16_op17.onnx
      Phhofm_HFA2kCompact_x2_fp16_op17.onnx
      Zarxrax_Anime1080Fixer_SUC_x1_fp16_op17.onnx
  portable_config/
    mpv.conf, input.conf, profiles.conf
    vs/, shaders/, tools/
```

ArtCNN 模型位于 `models/ArtCNN/`，自定义 UAI 模型位于 `models/` 根部，不能把它们全放进同一个子目录。具体来源与文件对应见 [VS 说明](../vs/README.md)。模型缺失或 DLL 不匹配时，基础导入检查可能通过，实际产帧检查会失败。

换电脑不要迁移 `.engine` 缓存；模型 `.onnx` 可以迁移。TensorRT 首次在新 GPU/新环境上构建引擎可能耗时，等初始化结束再判断实时性能。驱动要求由选用 CUDA/TensorRT 版本决定，不能拿本机驱动或旧的最低版本作为所有包的保证。

## 检查与验收

在 `portable_config` 下运行（或给脚本完整路径）：

```powershell
# 只检查运行时导入并列出 RTX 预设，不会把结果称为运行通过
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1

# 逐项验证 RTX VS 与新增 shader；shader 检查会短暂打开测试窗口
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1 -Run

# 单测一个预设，首次构建太慢可以提高单项超时
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1 -Run -Kind vs -Preset MEMC_RIFE_TRT -Timeout 600
```

脚本调用便携包 `python.exe`；测试别处的 mpv 可用 `-MpvRoot` 指定目录。只装 mpv 的 shader 用户可以直接按键播放验证；自动检查工具需要 Python，可在部署 VS 包后使用。检查工具忽略播放器配置以隔离依赖问题，不能代替最终配置的快捷键、下一文件与恢复默认回归。

VS 检查要求进程成功、日志存在、没有已知滤镜错误，并实际写出至少三张有效 PNG。shader 检查使用 `gpu-next` 的 2 倍窗口截图和 ArtCNN hook 注册日志，避免用 `vo=image` 假装验证 shader。日志、截图与 JSON 结果保存在 `cache/gpu-check/`，该目录不进 Git；进程失败、缺输出和超时返回非零退出码。报告的耗时包括初始化/编译/PNG，不是实时帧率。

## 用什么效果

| 需求 | 先试 | 需要时再试 |
| --- | --- | --- |
| SDR 动画放大，易部署 | C4F16 shader (`CTRL+ALT+1`) | C4F32 shader (`CTRL+ALT+2`)、AnimeJaNai VS (`*`) |
| 动画亮度重建 | ArtCNN C shader | ArtCNN R8F64 VS (`&`)，重画质档 |
| 4:2:0 BT.709 色度重建 | 原始输出作 A/B 基准 | ArtCNN Chroma VS (`ALT+&`) |
| 真人影视低分辨率放大 | 原始输出/既有缩放器作基准 | HFA2k VS (`(`)，检查纹理与伪细节 |
| 通用补帧 | RIFE TRT (`$`) | 动画 DRBA TRT (`%`)，检查运动边缘与切镜 |
| 轻微噪点 | Bilateral CUDA (`!`) | DFTTest CUDA (`+`) |
| 噪点较明显 | DFTTest CUDA (`+`) | BM3D CUDA (`'`)，检查细节损失 |

效果都按需开启，不自动给每段视频套降噪和补帧。先单项 A/B，再考虑组合，避免双重超分、重复降噪与显存争用。普通净源通常无需降噪；保留胶片颗粒时尤其谨慎。

既有 VS 超分的个人参数多为 `H_Pre=720`、`H_Max=1440`：高于 720p 的源可能先降到 720p 再处理，输出再限制到 1440p。这是控制负载的取舍，不是任意片源都保留原始细节的保证；表中的“2×”指模型倍率，不一定是原片最终尺寸倍率。迁移到不同屏幕先看各 `.vpy` 的参数；本轮保留这些调参，新增 C 系列 shader 跟随窗口输出尺度，适合先尝试的实时路线。

暂不新增 DPIR 去块/降噪：上游支持 RTX，但需要独立模型包（核对到约 460MiB）与额外引擎构建，当前机器未部署也未验证。Real-CUGAN、SCUNet 等也不能只凭名字就标为“效果更好”；后续有对应片源与模型，再选少量候选实测。

上游解释入口：[k7sfunc 参数与 GPU 后端](https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc)、[VS 用户滤镜](https://github.com/hooke007/mpv_PlayKit/wiki/3_FILTER)、[GLSL shader](https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL)、[ArtCNN 架构与模型用途](https://github.com/Artoriuz/ArtCNN)、[vs-mlrt 运行后端](https://github.com/AmusementClub/vs-mlrt/wiki)。
