# Lumina Studio 图像转换管道架构文档

## 概述

图像转换系统已经完全模块化，采用 **Pipeline + Step** 架构。每个处理步骤独立一个文件，通过 `PipelineContext` 传递数据，支持灵活地插入、移除、替换步骤。

系统包含两条管道：

- **光栅转换管道**（Raster Pipeline）：完整的图像→3D模型转换，12个步骤
- **预览管道**（Preview Pipeline）：快速预览生成，6个步骤

底层算法被抽离到 `core/processing/` 下的独立模块中，供 Pipeline Steps 调用。

---

## 架构层次

```
core/pipeline.py                  ← 管道框架（Pipeline, PipelineStep, PipelineContext）
core/pipeline_steps/              ← 光栅转换管道步骤（s01~s12）
core/preview_pipeline_steps/      ← 预览管道步骤（s01~s06）
core/processing/                  ← 底层处理算法模块（被 Steps 引用）
core/converter.py                 ← 遗留协调器（大量函数仍在此，逐步迁移中）
```

---

## 一、管道框架

| 文件               | 职责                                                                                                                                                            |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core/pipeline.py` | 定义 `PipelineContext`（上下文数据载体）、`PipelineStep`（步骤基类）、`Pipeline`（有序执行器）。支持 `insert_before/insert_after/remove/replace` 动态编辑管道。 |

---

## 二、光栅转换管道（12步）

由 `build_raster_pipeline()` 构建，完整的图像→3MF模型转换流程。

### 加工顺序

```
图片输入
  │
  ▼
┌─────────────────────────────────────────────┐
│ S01  InputValidationStep                    │  输入验证 + LUT路径解析
├─────────────────────────────────────────────┤
│ S02  ImageProcessingStep                    │  图像处理 + LUT颜色匹配
├─────────────────────────────────────────────┤
│ S03  ColorReplacementStep                   │  颜色替换（全局/区域）
├─────────────────────────────────────────────┤
│ S04  DebugPreviewStep                       │  Debug预览保存（可跳过）
├─────────────────────────────────────────────┤
│ S05  PreviewGenerationStep                  │  2D RGBA预览 + 挂件环
├─────────────────────────────────────────────┤
│ S06  VoxelBuildStep                         │  体素矩阵构建
├─────────────────────────────────────────────┤
│ S07  MeshGenerationStep                     │  多材质3D网格生成（并行）
├─────────────────────────────────────────────┤
│ S08  AddonMeshStep                          │  附加网格（底板/掐丝/描边/涂层/挂环）
├─────────────────────────────────────────────┤
│ S09  ExportStep                             │  坐标变换 + 3MF导出
├─────────────────────────────────────────────┤
│ S10  ColorRecipeStep                        │  颜色配方报告
├─────────────────────────────────────────────┤
│ S11  GlbPreviewStep                         │  GLB 3D预览导出
├─────────────────────────────────────────────┤
│ S12  FinalResultStep                        │  组装最终结果
└─────────────────────────────────────────────┘
  │
  ▼
输出：3MF文件 + GLB预览 + 2D预览图 + 配色报告
```

### 各步骤详细说明

| 序号 | 文件                        | 类名                    | 职责                                                                                                                                                                                     |
| ---- | --------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S01  | `s01_input_validation.py`   | `InputValidationStep`   | 验证 image_path、lut_path 是否有效；解析 LUT 文件路径；处理 `separate_backing` 标志和 `backing_color_id`                                                                                 |
| S02  | `s02_image_processing.py`   | `ImageProcessingStep`   | 调用 `LuminaImageProcessor` 执行核心图像处理：量化、LUT颜色匹配、生成 `matched_rgb`（匹配后RGB）、`material_matrix`（材料矩阵）、`mask_solid`（实体掩码）；加载 LUT 元数据和颜色系统配置 |
| S03  | `s03_color_replacement.py`  | `ColorReplacementStep`  | 处理三种颜色替换：① `matched_rgb_path` 外部覆盖 ② 全局颜色替换（hex→hex映射）③ 区域颜色替换（带mask的局部替换）。同步更新 `material_matrix`                                              |
| S04  | `s04_debug_preview.py`      | `DebugPreviewStep`      | 仅在高保真模式下执行，保存量化后的debug预览图（含轮廓线），用于调试矢量化输入                                                                                                            |
| S05  | `s05_preview_generation.py` | `PreviewGenerationStep` | 从 `matched_rgb` + `mask_solid` 生成 RGBA 预览图；计算挂件环位置信息并绘制到预览上                                                                                                       |
| S06  | `s06_voxel_build.py`        | `VoxelBuildStep`        | 根据模式构建3D体素矩阵。支持5种模式：flat（平面）、relief（浮雕）、heightmap（高度图）、cloisonné（景泰蓝）、faceup（单面朝上）。输出 `full_matrix (Z×H×W)`                              |
| S07  | `s07_mesh_generation.py`    | `MeshGenerationStep`    | 通过策略模式选择 mesher（HighFidelity/PixelArt），为每种材质并行生成3D mesh，组装到 `trimesh.Scene`                                                                                      |
| S08  | `s08_addon_mesh.py`         | `AddonMeshStep`         | 生成6种附加mesh：① 独立底板(Backing) ② 景泰蓝掐丝(Wire) ③ 自由颜色(Free Color) ④ 挂件环(Keychain Loop) ⑤ 透明涂层(Coating) ⑥ 外轮廓描边(Outline)                                         |
| S09  | `s09_export.py`             | `ExportStep`            | 应用坐标变换（镜像/翻转适配打印方向），调用 `bambu_3mf_writer` 导出带 BambuStudio 元数据的 3MF 文件                                                                                      |
| S10  | `s10_color_recipe.py`       | `ColorRecipeStep`       | 生成颜色配方报告（哪些LUT颜色被使用、像素占比等），支持通过环境变量控制策略（auto/on/off）                                                                                               |
| S11  | `s11_glb_preview.py`        | `GlbPreviewStep`        | 生成简化的 GLB 3D 预览文件，用于浏览器 Three.js 渲染。包含挂件环和描边的预览                                                                                                             |
| S12  | `s12_final_result.py`       | `FinalResultStep`       | 组装最终返回值元组 `(3mf_path, glb_path, preview_img, status_msg, recipe_path)`，输出计时统计                                                                                            |

---

## 三、预览管道（6步）

由 `build_preview_pipeline()` 构建，用于快速生成2D预览（不生成3D模型）。

### 加工顺序

```
图片输入
  │
  ▼
┌─────────────────────────────────────────────┐
│ S01  PreviewInputValidationStep             │  输入验证 + 参数规范化
├─────────────────────────────────────────────┤
│ S02  LutMetadataStep                        │  LUT元数据 + 颜色系统配置
├─────────────────────────────────────────────┤
│ S03  PreviewImageProcessingStep             │  核心图像处理（量化+匹配）
├─────────────────────────────────────────────┤
│ S04  CacheBuildStep                         │  构建预览缓存字典
├─────────────────────────────────────────────┤
│ S05  PaletteExtractionStep                  │  调色板提取
├─────────────────────────────────────────────┤
│ S06  PreviewRenderStep                      │  热床网格渲染 + 最终输出
└─────────────────────────────────────────────┘
  │
  ▼
输出：2D预览图 + 缓存字典 + 状态消息
```

### 各步骤详细说明

| 序号 | 文件                              | 类名                         | 职责                                                                                                          |
| ---- | --------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------- |
| S01  | `s01_preview_input_validation.py` | `PreviewInputValidationStep` | 验证 image_path、lut_path；规范化 modeling_mode（默认 HIGH_FIDELITY）；限制 quantize_colors 范围 [8, 256]     |
| S02  | `s02_lut_metadata.py`             | `LutMetadataStep`            | 通过 `LUTManager` 加载 LUT 校准文件的元数据；加载颜色系统配置（`ColorSystem.get(color_mode)`）                |
| S03  | `s03_image_processing.py`         | `PreviewImageProcessingStep` | 调用 `LuminaImageProcessor.process_image` 执行量化、颜色匹配，生成 matched_rgb / material_matrix / mask_solid |
| S04  | `s04_cache_build.py`              | `CacheBuildStep`             | 从处理结果构建 `preview_rgba`（RGBA预览图）和 `cache` 字典（包含所有中间数据，供API层和后续交互使用）         |
| S05  | `s05_palette_extraction.py`       | `PaletteExtractionStep`      | 确保 `quantized_image` 可用（缺失时自动回填）；提取唯一颜色调色板（颜色、hex值、像素数、占比）                |
| S06  | `s06_preview_render.py`           | `PreviewRenderStep`          | 调用 `render_preview` 在物理热床网格上渲染模型预览图；组装最终返回结果 `{display, cache, status}`             |

---

## 四、底层处理模块 (`core/processing/`)

每个算法独立一个文件，被 Pipeline Steps 引用调用。

| 文件                   | 职责                                                                     | 被哪个Step调用                        |
| ---------------------- | ------------------------------------------------------------------------ | ------------------------------------- |
| `color_replacement.py` | 颜色替换工具：hex→rgb转换、输入归一化（兼容dict/list格式）、区域替换应用 | S03 ColorReplacementStep              |
| `debug_preview.py`     | 保存高保真模式debug预览图（量化图+轮廓线叠加）                           | S04 DebugPreviewStep                  |
| `loop_utils.py`        | 挂件环计算：位置吸附、尺寸计算、预览绘制                                 | S05 PreviewGenerationStep             |
| `voxel_builder.py`     | 体素矩阵构建：flat/relief/heightmap/cloisonné/faceup 五种模式            | S06 VoxelBuildStep                    |
| `mesh_builder.py`      | 多材质mesh并行生成，组装到 `trimesh.Scene`，应用变换和颜色               | S07 MeshGenerationStep                |
| `backing_mesh.py`      | 独立底板mesh生成（mat_id=-2）                                            | S08 AddonMeshStep                     |
| `wire_mesh.py`         | 景泰蓝掐丝mesh生成（mat_id=-3，金色）                                    | S08 AddonMeshStep                     |
| `free_color_mesh.py`   | 自由颜色提取：将指定hex颜色的像素区域提取为独立mesh对象                  | S08 AddonMeshStep                     |
| `coating_mesh.py`      | 透明涂层mesh生成（覆盖模型表面，支持扩展到描边区域）                     | S08 AddonMeshStep                     |
| `outline_mesh.py`      | 外轮廓描边mesh生成（膨胀-原始=环形，贪心矩形合并优化）                   | S08 AddonMeshStep, S11 GlbPreviewStep |
| `scene_transform.py`   | 坐标变换：根据颜色模式和打印结构模式应用镜像/翻转                        | S09 ExportStep                        |
| `preview_cache.py`     | 预览缓存构建：生成 RGBA 预览图 + 组装 cache 字典                         | 预览S04 CacheBuildStep                |
| `palette.py`           | 调色板提取：统计唯一颜色、像素数、占比；确保 quantized_image 可用        | 预览S05 PaletteExtractionStep         |
| `preview_render.py`    | 预览渲染：在物理热床网格上渲染模型，支持深色/浅色主题、挂件环叠加        | 预览S06 PreviewRenderStep             |
| `preview_mesh.py`      | 3D预览mesh生成：为浏览器创建简化的彩色体素预览（大图自动降采样）         | S11 GlbPreviewStep                    |

---

## 五、核心支撑模块 (`core/`)

| 文件                          | 职责                                                                             |
| ----------------------------- | -------------------------------------------------------------------------------- |
| `image_processing.py`         | `LuminaImageProcessor` 类：图像量化、LUT颜色匹配、KD-Tree查询、材料矩阵生成      |
| `color_matching_hue_aware.py` | 色相感知颜色匹配算法（hue_weight / chroma_gate 参数）                            |
| `color_replacement.py`        | `ColorReplacementManager` 类：全局颜色替换管理器                                 |
| `mesh_generators.py`          | 策略模式：`get_mesher()` 选择 HighFidelityMesher 或 PixelArtMesher               |
| `heightmap_loader.py`         | `HeightmapLoader`：加载和处理高度图，生成高度矩阵                                |
| `geometry_utils.py`           | 几何工具：挂件环3D模型创建 (`create_keychain_loop`)                              |
| `vector_engine.py`            | 矢量化引擎：SVG路径解析和矢量化处理                                              |
| `naming.py`                   | 文件命名生成器：模型文件名、预览文件名                                           |
| `converter.py`                | 遗留协调器（2500+行），包含大量尚未迁移到管道的函数（GLB生成、交互式预览更新等） |

---

## 六、数据流概览

```
image_path + lut_path
       │
       ▼
  LuminaImageProcessor.process_image()
       │
       ├── matched_rgb      (H,W,3) uint8  匹配后的RGB图像
       ├── material_matrix   (H,W,N) int    每像素的材料堆叠ID
       ├── mask_solid        (H,W)   bool   实体/透明掩码
       ├── pixel_scale       float          mm/像素
       └── dimensions        (W,H)          目标尺寸
       │
       ▼  [颜色替换]
  matched_rgb' + material_matrix'
       │
       ▼  [体素构建]
  full_matrix  (Z,H,W) int    3D体素矩阵
       │
       ▼  [网格生成]
  trimesh.Scene (多材质mesh)
       │
       ▼  [附加mesh + 坐标变换]
  trimesh.Scene (完整场景)
       │
       ├── 3MF导出 → output/*.3mf
       ├── GLB预览 → output/*.glb
       ├── 2D预览  → PIL.Image (RGBA)
       └── 配色报告 → output/*.html
```

---

## 七、扩展方式

管道设计支持灵活扩展：

```python
from core.pipeline_steps import build_raster_pipeline

pipeline = build_raster_pipeline()

# 在颜色替换后插入自定义降噪步骤
pipeline.insert_after('ColorReplacementStep', MyDenoiseStep())

# 移除不需要的debug预览
pipeline.remove('DebugPreviewStep')

# 替换体素构建为自定义实现
pipeline.replace('VoxelBuildStep', MyCustomVoxelStep())

# 执行
ctx = PipelineContext(params={...})
ctx = pipeline.run(ctx)
```
