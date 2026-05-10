# Pet Runtime Contract For New App

这份文档给另一个桌面宠物 app 使用。

如果那个 app 以前是播放 `.mov`，现在要改成播放 Codex 风格宠物，它不能只“读取图片”。它必须实现下面这套固定播放协议。

## 1. 要复制过去的文件

每只宠物最终只需要复制这两个文件：

```text
goldie/
├── pet.json
└── spritesheet.webp
```

Goldie 当前源文件在：

```text
/Users/ricky/.codex/pets/goldie/pet.json
/Users/ricky/.codex/pets/goldie/spritesheet.webp
```

如果只是给新 app 测试，也可以复制到任意 app 能读到的目录，只要保持这两个文件在同一个文件夹。

## 2. pet.json 只提供元数据

当前 `pet.json` 类似：

```json
{
  "id": "goldie",
  "displayName": "Goldie",
  "description": "A warm tiny golden retriever desk companion.",
  "spritesheetPath": "spritesheet.webp"
}
```

它只告诉 app：

```text
这只宠物的 id
显示名
描述
spritesheet 文件名
```

它不包含每帧坐标和时间。

原因是：Codex 风格宠物的坐标、状态、时长是一个固定协议，由播放器代码实现。

## 3. 新 app 必须内置这些常量

新 app 必须知道：

```text
frameWidth = 192
frameHeight = 208
columns = 8
rows = 9
spritesheetWidth = 1536
spritesheetHeight = 1872
```

也就是：

```text
每格 192 x 208
整张图 8 列 x 9 行
整张图 1536 x 1872
```

## 4. 新 app 必须内置状态行表

每一行代表一个状态：

```text
row 0 = idle
row 1 = running-right
row 2 = running-left
row 3 = waving
row 4 = jumping
row 5 = failed
row 6 = waiting
row 7 = running
row 8 = review
```

注意：

```text
running-right / running-left 是左右移动动画
running 是任务进行中动画，不是字面跑步
```

## 5. 新 app 必须内置每个状态的帧数和时长

建议直接把下面这张表写进新 app 的播放器代码。

```js
const animations = {
  idle: {
    row: 0,
    durations: [280, 110, 110, 140, 140, 320],
    loop: true
  },
  "running-right": {
    row: 1,
    durations: [120, 120, 120, 120, 120, 120, 120, 220],
    loop: true
  },
  "running-left": {
    row: 2,
    durations: [120, 120, 120, 120, 120, 120, 120, 220],
    loop: true
  },
  waving: {
    row: 3,
    durations: [140, 140, 140, 280],
    loop: false,
    fallback: "idle"
  },
  jumping: {
    row: 4,
    durations: [140, 140, 140, 140, 280],
    loop: false,
    fallback: "idle"
  },
  failed: {
    row: 5,
    durations: [140, 140, 140, 140, 140, 140, 140, 240],
    loop: false,
    fallback: "idle"
  },
  waiting: {
    row: 6,
    durations: [150, 150, 150, 150, 150, 260],
    loop: true
  },
  running: {
    row: 7,
    durations: [120, 120, 120, 120, 120, 220],
    loop: true
  },
  review: {
    row: 8,
    durations: [150, 150, 150, 150, 150, 280],
    loop: true
  }
}
```

`durations.length` 就是这个状态使用的帧数。

未使用的格子不播放，应该保持透明。

## 6. 新 app 怎么显示某一帧

假设要显示：

```text
row = 3
column = 2
```

也就是 `waving` 的第 3 个画面。

偏移公式是：

```text
x = -column * 192
y = -row * 208
```

所以：

```text
x = -2 * 192 = -384
y = -3 * 208 = -624
```

如果是 WebView / HTML 播放，可以这样：

```js
pet.style.backgroundPosition = `${x}px ${y}px`
```

如果是原生 Canvas / NSImage / CALayer 播放，就等价于：

```text
从 spritesheet.webp 裁剪 rect:
x = column * 192
y = row * 208
width = 192
height = 208

然后把这块画到桌面宠物窗口里。
```

Web/CSS 用负数偏移。

原生裁剪用正数坐标。

## 7. 新 app 的播放循环

伪代码：

```js
let currentState = "idle"
let animationStartTime = performance.now()

function play(state) {
  currentState = state
  animationStartTime = performance.now()
}

function tick(now) {
  const animation = animations[currentState]
  const elapsed = now - animationStartTime
  const total = sum(animation.durations)

  let localTime = elapsed
  if (animation.loop) {
    localTime = elapsed % total
  } else if (elapsed >= total) {
    play(animation.fallback || "idle")
    return
  }

  const column = findFrameIndex(animation.durations, localTime)
  const row = animation.row

  showCell(row, column)
  requestAnimationFrame(tick)
}
```

`showCell(row, column)` 就是按第 6 节的公式显示对应格子。

## 8. 新 app 的状态切换

新 app 自己决定什么时候调用哪个状态。

建议映射：

```text
app 启动 -> idle
点击宠物 -> waving
任务开始 -> running
等待工具/网络 -> waiting
审阅/检查 -> review
任务失败 -> failed
向右移动 -> running-right
向左移动 -> running-left
```

非循环动作：

```text
waving 播完回 idle
jumping 播完回 idle
failed 播完回 idle 或 waiting
```

## 9. 如果新 app 以前播放 MOV

旧逻辑可能是：

```text
idle.mov
walk.mov
fail.mov
```

新逻辑要改成：

```text
load pet.json
load spritesheet.webp
currentState = idle
按 currentState 的 row 和 durations 切 column
```

也就是说，不再让视频文件自己决定时间轴。

时间轴由新 app 的播放器代码决定。

## 10. 最低验收标准

新 app 接入成功至少要满足：

```text
能读取 pet.json
能找到同目录 spritesheet.webp
能显示 192 x 208 的一格
idle 能循环播放 6 帧
waving 能播放 4 帧后回 idle
running-right / running-left 能播放 8 帧
failed 能播放 8 帧后回 idle
窗口背景透明
不会显示整张 spritesheet
不会显示粉色/白色背景块
```

## 11. 一句话总结

要拖过去的文件只有：

```text
pet.json
spritesheet.webp
```

但新 app 必须实现这份文档里的播放器规则：

```text
固定格子尺寸
固定状态行
固定每帧时长
按 row/column 裁剪或偏移显示
按 app 状态切换动画
```

