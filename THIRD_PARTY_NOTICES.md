# 第三方服务与开源说明

## memecub

- 仓库：https://github.com/liyupi/memecub
- API 文档：https://memecub.com/developers
- 接入方式：根据公开 REST API 编写原生 Swift 适配层，没有引入 Node、MCP 运行时或远程可执行代码。
- 2026-11-16 核查 GitHub API：仓库创建于 2026-10-13，最近推送于 2026-11-11，36 stars。选择依据是近期维护、中文搜索及 JPG/PNG/GIF 支持，不宣称其为高星项目。
- 该仓库的客户端及集成代码使用 MIT 许可证；网站、图库与数据管线不开放源码。图片不属于 MIT 许可，权利及署名见各图片来源页。
- 搜索使用 `GET https://memecub.com/api/v1/search?q=...&limit=N`。匿名用户按 IP 每日 20 次，可能有临时频率限制；本项目未配置付费账号或 API 密钥。
- 每次回车或点击搜索才请求一次；静图/动图筛选在当前结果内执行，不消耗额外查询。服务不可用或额度用尽时显示此关键词未过期的本地缓存，无有效缓存才显示错误；不自动循环重试。
- 关键词发送至 memecub；加载图片会访问结果提供的 HTTPS 图片服务器。不会上传剪贴板历史或本机文件。
- 图片下载限制为 16 MB、单帧 2000 万像素、动画累计 1.2 亿像素；临时原始数据内存缓存目标上限 48 MB。搜索分配额度内的缩略图和原图后台写入本地缓存（每源最多四路预下载），默认 72 小时后自动删除，保留天数可在设置中修改。每次成功刷新重置该关键词时间，回退读取不续期。复制的原图另外进入现有剪贴板目录和清理策略。

以下保留上游 MIT 许可证（2026-11-16 读取），便于以后引入其客户端代码时查阅：

MIT License

Copyright (c) 2026 Cyber Koi Limited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## 新增搜索来源（2026-11-16）

| 来源 | 公开说明 | 接入方式 |
| --- | --- | --- |
| 慕名表情 | [接口文档](https://xiaoapi.cn/detail/10) | `GET https://xiaoapi.cn/v1/meme.php?msg=...&num=N&page=1`，解析 `data[].img_url`，无需密钥 |
| 澄曜搜狗表情 | [接口文档](https://api.ruseo.cn/api-doc/sogou_bqb) | `GET https://api.ruseo.cn/api/sogou_bqb?words=...&page=1`，解析 `data.res`，无需密钥；文档标注每分钟 100 次 |
| ChineseBQB | [开源仓库](https://github.com/zhaoolee/ChineseBQB)、[图库](https://zhaoolee.com/ChineseBQB/) | 下载 `catalog/search.json`，在本机按名称、分类匹配关键词，使用目录提供的原图及缩略图 |
| 皮蛋表情包 | [公开网站](https://pdan.com.cn/) | 搜索 `https://pdan.com.cn/?s=...`，仅读取 `postlist` 内图片链接；站点结构变化时会报告来源失效 |

ChineseBQB 核查时约 16.6k stars，公开目录包含静图与 GIF。上述接入均为独立编写的 Swift 协议适配，没有复制第三方实现、嵌入图片集合或执行网页脚本。公开 API/网页可访问不代表服务端开源，图片权利不由客户端代码许可证授予；每条结果保留可用的来源页链接。

搜索只请求已勾选的来源，至少选择一个；默认保留旧版 memecub 单选。默认数量按 `floor(50 / 来源数)` 分配，三源各 16，五源各 10。可自定义各源 1～50 条，总量按设置相加；接口忽略数量参数时也会在本机截取。结果按用户拖动后的来源顺序依次显示，跨源重复图片保留较前的来源；返回不足时不额外消耗请求补齐。

缓存使用「关键词 + 来源组合 + 各源分配数量 + 具体来源」分区，默认均分兼容旧缓存。排序不影响分区，离线时也可按新顺序展示旧缓存；改变数量则使用对应数量的独立分区。每个来源独立刷新和回退；成功来源不会延长失败来源旧缓存的时间。默认 3 天、设置中可调 1～365 天，原图和缩略图沿用相同过期清理流程。多源会分别显示更新、缓存回退或失败信息；全部失败且无有效缓存时显示错误。

「本地」分类完全独立于第三方搜索服务。用户选择的静图、动图及自定义名称只写入本机 `Application Support/MacTools/LocalMemes`，不上传、不参与搜索缓存或剪贴板历史的定期清理；仅根据用户操作增删改。

关键词只发送到所选搜索服务；ChineseBQB 只下载公开目录，关键词在本机匹配。加载图片会访问各结果提供的 HTTPS 服务器。原生 TLS 校验保持开启，不绕过接口访问限制。未接入斗图啦：原生 URLSession 实测出现 TLS 失败。memecub 在本次复查中返回 HTTP 403，已保留缓存回退和其他来源选择能力。
