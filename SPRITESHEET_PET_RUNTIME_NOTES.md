# Spritesheet Pet Runtime Notes

这份文档写给之后的 Codex 自己看：如果要把一个“播放 MOV 的桌面宠物 app”改造成 Codex 风格宠物 app，核心目标是把运行时从“按视频文件播放”改成“读取 `pet.json`，加载 `spritesheet.webp`，按状态显示图集里的格子”。

## 1. 最终运行时只需要两个文件

一个宠物包最小结构是：

```text
~/.codex/pets/<pet-id>/
├── pet.json
└── spritesheet.webp
```

`pet.json` 是说明书。

`spritesheet.webp` 是所有动作帧合成后的一张大图。

运行时不需要 `frames/`、`decoded/`、`prompts/`、`qa/`。这些都是生产和检查过程用的中间文件。

## 2. pet.json 的职责

最小 `pet.json`：

```json
{
  "id": "goldie",
  "displayName": "Goldie",
  "description": "A warm tiny golden retriever desk companion.",
  "spritesheetPath": "spritesheet.webp"
}
```

App 做的事情：

1. 扫描 `~/.codex/pets/`。
2. 找到每个子目录里的 `pet.json`。
3. 读取 `spritesheetPath`。
4. 加载同目录下的 `spritesheet.webp`。
5. 把这个宠物加入可选列表。

注意：宠物包应该被当作数据，不要执行宠物目录里的 JS 或脚本。

## 3. spritesheet.webp 的固定规格

Codex 风格宠物图集固定为：

```text
尺寸：1536 x 1872
网格：8 列 x 9 行
单格：192 x 208
格式：WebP 或 PNG，通常用 WebP
背景：透明
未使用格：完全透明
```

换算：

```text
8 * 192 = 1536
9 * 208 = 1872
```

每一格就是一帧。

## 4. 9 行状态定义

图集每一行代表一个固定状态：

| Row | State | Used Columns |
| --- | --- | ---: |
| 0 | `idle` | 0-5 |
| 1 | `running-right` | 0-7 |
| 2 | `running-left` | 0-7 |
| 3 | `waving` | 0-3 |
| 4 | `jumping` | 0-4 |
| 5 | `failed` | 0-7 |
| 6 | `waiting` | 0-5 |
| 7 | `running` | 0-5 |
| 8 | `review` | 0-5 |

不要混淆：

```text
running-right / running-left = 宠物朝左右移动
running = Codex 或 app 正在执行任务，不是字面意义的跑步
```

## 5. 每帧时长

不要用一个统一 FPS 粗略播放。更接近 Codex 的方式是每一帧有自己的 duration：

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

## 6. 播放原理

旧 MOV app 的思路通常是：

```text
状态变化 -> 换一个 .mov -> 视频自己播放
```

Spritesheet app 的思路是：

```text
状态变化 -> 选择 spritesheet 的某一行 -> App 自己按时间切列
```

也就是说：

```text
不是播放很多视频
而是加载一张大图
用一个 192 x 208 的窗口露出其中一格
不断切换露出的格子
```

Web/CSS 里通常用：

```css
#pet {
  width: 192px;
  height: 208px;
  background-image: url("spritesheet.webp");
  background-repeat: no-repeat;
}
```

显示第 `row` 行、第 `column` 列：

```js
const x = -column * 192
const y = -row * 208
pet.style.backgroundPosition = `${x}px ${y}px`
```

例子：

```text
idle 第 0 帧：row=0, column=0 -> 0px 0px
idle 第 3 帧：row=0, column=3 -> -576px 0px
waving 第 2 帧：row=3, column=2 -> -384px -624px
```

## 7. Native App 应该负责什么

如果另一个桌面宠物 app 是 macOS 原生 app，它应该负责：

```text
透明窗口
置顶
拖拽
菜单
设置
宠物包扫描
状态机
把状态传给播放器
```

如果用 WKWebView 播 spritesheet，则：

```text
Native 层负责窗口和系统能力
WebView 层负责显示和切帧
```

Native 调 JS 的接口可以是：

```js
window.petPlayer.play("running")
window.petPlayer.play("review")
window.petPlayer.play("failed")
window.petPlayer.loadPet({ spritesheetUrl: "..." })
window.petPlayer.setPlaybackRate(1)
window.petPlayer.setPetScale(1.2)
```

## 8. 状态机建议

App 状态映射到宠物状态：

| App Event | Pet State |
| --- | --- |
| app ready | `idle` |
| user clicked pet | `waving` |
| task starts | `running` |
| waiting on tool/network | `waiting` |
| reviewing/checking | `review` |
| task failed | `failed` |
| pet moves right | `running-right` |
| pet moves left | `running-left` |

非循环状态播完要回 fallback：

```text
waving -> idle
jumping -> idle
failed -> idle 或 waiting
```

## 9. 从 MOV 播放迁移到 spritesheet 播放

旧逻辑可能长这样：

```text
idle.mov
walk.mov
happy.mov
fail.mov
```

迁移后不要再按文件切视频，而是：

```text
idle -> spritesheet row 0
running-right -> spritesheet row 1
running-left -> spritesheet row 2
waving -> spritesheet row 3
jumping -> spritesheet row 4
failed -> spritesheet row 5
waiting -> spritesheet row 6
running -> spritesheet row 7
review -> spritesheet row 8
```

关键改造点：

1. 删除或旁路 MOV 播放器。
2. 添加 Pet Package Loader，扫描 `~/.codex/pets/`。
3. 添加 spritesheet 播放器。
4. 用 app 状态调用 `play(state)`。
5. 用每帧 duration 控制动画，而不是视频文件时间轴。
6. 保留透明窗口、拖拽、置顶、菜单等原生壳能力。

## 10. 最小实现

最小可用版本：

```text
1. 启动 app
2. 扫描 ~/.codex/pets/
3. 读取 pet.json
4. 加载 spritesheet.webp
5. 默认播放 idle
6. 点击宠物播放 waving
7. 菜单或内部事件切 running / waiting / review / failed
```

桌面上最终只需要显示一块透明窗口，窗口内容是当前 `row + column` 的那一格。

## 11. 和 frames/ 的关系

`frames/` 是生产过程里的单帧目录，例如：

```text
frames/idle/00.png
frames/idle/01.png
```

运行时不需要它。

运行时只需要：

```text
pet.json
spritesheet.webp
```

可以这样理解：

```text
frames/ = 原材料
spritesheet.webp = 成品图集
pet.json = 成品说明书
desktop app = 播放器
```

## 12. 改造时的验收标准

改造另一个桌面宠物 app 后，至少要满足：

```text
能加载 ~/.codex/pets/goldie/pet.json
能显示 ~/.codex/pets/goldie/spritesheet.webp
默认 idle 正常循环
点击能触发 waving，播完回 idle
running / waiting / review / failed 能通过代码或菜单切换
透明窗口正常
拖拽窗口正常
图像边缘透明，没有背景色块
不再依赖 MOV 才能播放宠物
```

