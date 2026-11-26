# 编写 Exit 特效

[English](EFFECTS.md)

一个 Exit 特效就是一个 `.metal` 文件。把它放进
`~/Library/Application Support/Exit/Effects/`，菜单里马上就能看到。
每次保存都会立即重新编译，编译错误显示在“设置 → 特效”里。
和内置特效同名的文件会替换掉那个内置特效。

## 约定

你只需要写一个 Metal 着色语言（MSL）函数。它在每一帧里，对覆盖在窗口位置上的
透明画布的每个像素各运行一次：

```metal
float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    // ...
}
```

* `p`：当前像素，单位是画布像素。原点在**左上角**，y 向下增大。
* `u`：uniform 参数，见下文。
* `tex`：窗口的画面（没有录屏权限时是一张替代卡片）。
  不要直接采样它，请用 `sampleWindow(tex, u, pos)` 或 `sampleWindowUV(tex, uv)`。
* 返回**预乘 alpha** 的颜色：`float4(rgb * a, a)`。`float4(0)` 表示什么都不画。
  `rgb` 可以大于 `a`，用来在背后的内容上叠加光（辉光、火花、闪光）。

画布是窗口矩形向四周各扩大 `@padding` 点（超出屏幕的部分会被裁掉），所以你可以
画到窗口外面：粒子、阴影、辉光都行。

你的文件前面会自动拼上一段 prelude 一起编译。不要 `#include` 任何东西，也不要
重新定义 prelude 里已有的名字。

## 文件头

文件开头是若干行 `// @key value` 注释：

```metal
// @name Old TV
// @name.zh 老电视
// @author Your Name
// @description CRT power-off: collapses to a glowing line, then a dot.
// @description.zh 显像管关机：压成一道亮线，再缩成一个光点。
// @duration 0.62
// @padding 120
// @events close, quit, minimize
```

| 键 | 含义 | 默认值 |
|---|---|---|
| `@name`、`@name.zh` | 显示名称（英文 / 中文） | 文件名 |
| `@description`、`@description.zh` | 设置里显示的一句话说明 | 无 |
| `@duration` | 时长（秒），0.15 – 6 | 0.7 |
| `@padding` | 窗口四周额外的画布宽度（点）；写 `screen` 表示整个屏幕 | 160 |
| `@events` | `close`、`quit`、`minimize`、`open` 中的任意几个 | `close, quit, minimize` |

## Uniform 参数：`constant Exit& u`

| 字段 | 类型 | 含义 |
|---|---|---|
| `u.progress` | float | 在整个时长内从 0 线性走到 1。缓动要自己加。 |
| `u.time` | float | 从开始到现在的秒数 |
| `u.duration` | float | 总秒数（已经按用户设置的速度换算过） |
| `u.win` | float4 | 窗口在画布上的矩形，单位像素：`(x, y, 宽, 高)` |
| `u.size` | float2 | 画布尺寸，单位像素 |
| `u.cursor` | float2 | 特效开始时鼠标在画布上的位置（像素），通常就是用户点关闭按钮的地方 |
| `u.seed` | float | 0..1 的随机数，每次播放都不同，可以用来变换方向、颜色和布局 |
| `u.scale` | float | 每点对应的像素数（Retina 屏上是 2）。所有尺寸都要乘上它：`8.0 * u.scale` |
| `u.event` | int | `EVENT_CLOSE`、`EVENT_QUIT`、`EVENT_MINIMIZE` 或 `EVENT_OPEN` |
| `u.hasSnapshot` | int | 1 表示真实的窗口画面，0 表示替代卡片 |
| `u.corner` | float | 窗口圆角半径，单位像素 |
| `u.accent` | float4 | 用户的系统强调色 (rgb, 1) |

## Prelude 里的工具函数

窗口坐标

* `float2 toWindowUV(u, p)`：画布像素 → 窗口 uv（窗口内为 0..1，原点在左上角）
* `float2 fromWindowUV(u, uv)`：窗口 uv → 画布像素
* `float2 windowCenter(u)`、`float2 windowSize(u)`
* `float4 sampleWindow(tex, u, p)`：画布像素 `p` 处的窗口颜色，窗口外是透明
* `float4 sampleWindowUV(tex, uv)`：窗口 uv 处的窗口颜色，0..1 以外是透明
* `sampleWindowSharp(tex, u, p)`、`sampleWindowUVSharp(tex, uv)`：同上，但始终用原始分辨率采样。
  **在循环里、以及相邻像素会走不同分支的地方（粒子、碎片、格子）要用这两个**：
  那些地方自动选择的 mipmap 层级是不确定的，会把窗口的平均色糊到窗口外很远的地方。
  平滑的变形用普通版本就行。
* `float windowSDF(u, p)`：到圆角窗口轮廓的有符号距离，单位像素（窗口内为负）

形状：`sdCircle(p, r)`、`sdBox(p, halfSize)`、`sdRoundBox(p, halfSize, r)`、`sdSegment(p, a, b)`、`float2x2 rot(angle)`

随机与噪声：`hash11(float)`、`hash21(float2)`、`float2 hash22(float2)`、`float3 hash32(float2)`（都返回 0..1），
`noise(float2)`（平滑的值噪声，0..1）、`fbm(float2, octaves)`

缓动（输入和输出都是 0..1）：`easeInQuad`、`easeOutQuad`、`easeInOutQuad`、`easeInCubic`、
`easeOutCubic`、`easeInOutCubic`、`easeInExpo`、`easeOutExpo`、`easeInBack`、`easeOutBack`、
`easeOutElastic`，以及 `remap01(x, a, b)`：把 `[a, b]` 映射到 `[0, 1]` 并截断。

颜色：`hsv2rgb(float3)`、`palette(t, a, b, c, d)`（余弦调色板）、`luminance(rgb)`、
`premul(rgb, alpha)`、`over(top, bottom)`（预乘 alpha 合成）

常量：`PI`、`TAU`、`EVENT_CLOSE`、`EVENT_OPEN`、`EVENT_MINIMIZE`、`EVENT_QUIT`。

## 让特效看起来对劲的几条规则

1. **开头无缝衔接（关闭 / 退出 / 最小化）。** 特效开始的那一刻真实窗口就消失了，所以
   `progress == 0` 时的输出必须和 `sampleWindow(tex, u, p)` 完全一样：还不能有位移、缩放、
   染色、辉光或阴影。所有变化都要逐渐加进来。
2. **结尾干净。** `progress == 1` 时所有像素都返回 `float4(0)`。
3. **打开特效只做装饰。** 对 `@events open` 来说，真实窗口一直显示在下面。
   只画光和点缀（alpha 保持很低，用 rgb 叠加光），开头和结尾都要完全透明，
   也不要把窗口本身再画一遍盖在它上面。
4. **不依赖分辨率。** 尺寸用“点数 × `u.scale`”表示，位置相对于 `u.win` 计算。
   窗口可能很小也可能全屏，可能很宽也可能很高。
5. **要快。** 着色器以 120 fps 在几百万个像素上运行。循环要短（几十次，而不是几千次），
   不会受影响的像素尽早跳过；能用网格查找解决的，就不要让每个像素遍历所有粒子。
6. **会动的碎片要反向映射。** 片元着色器没法把像素“推”到别处；要对每个输出像素反过来问：
   “窗口的哪一块落到了这里？”常用做法：对每块碎片求变换的逆，检查源点是否属于这块碎片；
   对朝同一方向飘的粒子，沿这个方向反向逐格检查候选格子。

## 完整示例

```metal
// @name Fade Away
// @name.zh 淡出
// @description Shrinks slightly and fades out.
// @description.zh 轻轻缩小并淡出。
// @duration 0.35
// @padding 0
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = easeInCubic(u.progress);
    float s = 1.0 - 0.08 * t;                         // 以中心为基准缩放
    float2 c = windowCenter(u);
    float4 col = sampleWindow(tex, u, c + (p - c) / s);
    return col * (1.0 - t);
}
```

## 不关窗口也能试特效

* “设置 → 特效 → 预览”会在演示窗口上播放它。
* 在终端里：`Exit.app/Contents/MacOS/Exit --check` 编译所有特效并输出错误；
  `--render-sheet out.png --only my-effect` 渲染一排逐帧画面。
