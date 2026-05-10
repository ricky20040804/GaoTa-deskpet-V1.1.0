# Generate Pet Prototype

本目录是桌面宠物生成流水线的本地原型。

现在的运行器协议已经简化为：

```text
spritesheet.webp
尺寸：1536 x 768
网格：8 列 x 4 行
单格：192 x 192
```

行定义：

```text
row 0 = idle
row 1 = running
row 2 = failed
row 3 = tail-wagging
```

App 里：

```text
running-right = row 1 正常播放
running-left = row 1 水平翻转播放
jumping = tail-wagging
waiting / running / review = idle
```

输出宠物包：

```text
<pet-id>/
  pet.json
  spritesheet.webp
  preview.png
  <pet-id>.zip
```

## 快速本地验证

不调用 API，只用一张静态图生成可运行宠物包：

```bash
/Users/ricky/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  Tools/generate_pet/generate_pet.py \
  --input icon.png \
  --name TestPet \
  --description "A test desktop pet." \
  --from-static
```

## 调用通义万相生成

脚本默认使用阿里云 DashScope 的 `wan2.6-image`，并要求模型一次生成完整 `4 x 8` spritesheet：

```bash
export DASHSCOPE_API_KEY="你的 DashScope API Key"

/Users/ricky/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  Tools/generate_pet/generate_pet.py \
  --input character.png \
  --name 小白 \
  --description "一只戴红围巾的白色小猫桌面宠物" \
  --style "可爱的2D贴纸风格，绿幕背景，Q版，全身小猫，尾巴动作清楚" \
  --keep-intermediates
```

`--keep-intermediates` 会保存 API 返回的原图：

```text
raw-spritesheet.png
```

如果你的 API Key 属于国际站或其他区域，可以改 endpoint：

```bash
--dashscope-endpoint https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
```

或：

```bash
--dashscope-endpoint https://dashscope-us.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
```

## 兼容旧动作条

如果手上已有旧版本生成的四张动作条：

```text
idle-strip.png
running-right-strip.png
failed-strip.png
tail-wagging-strip.png 或 waving-strip.png
```

可以不重新调用 API，直接重建新的 `4 x 8` spritesheet：

```bash
/Users/ricky/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  Tools/generate_pet/generate_pet.py \
  --rebuild-from-strips GeneratedPets/pet-nk78gs \
  --name 小白 \
  --description "一只可爱的桌面宠物" \
  --id pet-nk78gs-4x8 \
  --output GeneratedPets
```

## 后续适合增强的地方

- 自动检查是否真的是 `4 x 8` 网格
- 自动检测格子里是否有文字、边框、背景
- 生成失败时提示用户重新生成
- 加网页，把这个脚本封装成上传、预览、下载流程
