# `.library` 素材库存储格式（Eagle 兼容）

> 根据一个实际的 Eagle 库逆向整理（`applicationVersion: "4.0.0"`，2347 个条目、130 个文件夹）。
> 这是 Eagle 的库格式：**没有数据库引擎，全部是普通文件 + JSON**。
> 标注「观察到」的字段只在部分条目里出现，属于可选字段。

## 1. 目录结构

```
XXX.library/
├── metadata.json        # 库级元数据：文件夹树、智能文件夹、快速访问、标签组
├── tags.json            # 最近使用标签 / 星标标签
├── mtime.json           # 条目 id → 最后修改时间 的索引，外加总数 "all"
├── actions.json         # []，用途未知（推测为自动化动作）
├── saved-filters.json   # []，保存的筛选条件
├── backup/              # metadata.json 的历史快照
│   └── backup-YYYY-MM-DD HH.MM.SS.mmm.json
├── images/              # 每个素材一个目录
│   └── <ITEM_ID>.info/
│       ├── metadata.json
│       ├── <name>.<ext>              # 原文件
│       └── <name>_thumbnail.png      # 缩略图（可选）
└── Icon                 # macOS 自定义图标占位文件（Icon\r），0 字节，可忽略
```

要点：
- **标签和文件夹归属都存在每个条目自己的 `metadata.json` 里**，库级 `metadata.json` 只存文件夹树本身。全库没有「标签总表」，标签集合要扫描所有条目汇总得到。
- 读取整个库 = 读 `metadata.json` + 遍历 `images/*.info/metadata.json`。启动时应该建内存索引（或自己的 SQLite 缓存），用 `mtime.json` 做增量刷新。

## 2. ID 规则

- 条目和文件夹的 ID 都是 **13 位大写字母和数字**（`[0-9A-Z]{13}`），例如 `LZUQQ1UF05YG0`。
- 前 8 位左右看起来是时间戳的 base36 编码（同一批导入的 ID 前缀相同，如 `LZUQQWE7…`），后几位是随机串。
  - 例：`parseInt("LZUQQ1UF", 36)` ≈ 1723693698…（毫秒时间戳，2024-08-15），与 modificationTime 吻合。
- 自己生成新 ID 时：`Date.now().toString(36).toUpperCase()`（8 位）+ 5 位随机 `[0-9A-Z]`，保证 13 位且不冲突即可。

## 3. 时间戳

所有时间都是 **Unix 毫秒时间戳（整数）**。

## 4. 库级 `metadata.json`

```json
{
  "folders": [ Folder, ... ],     // 顶层文件夹，递归嵌套
  "smartFolders": [],             // 智能文件夹（本库为空，结构待补）
  "quickAccess": [],              // 侧栏快速访问（本库为空）
  "tagsGroups": [],               // 标签分组（本库为空）
  "modificationTime": 1791476474563,
  "applicationVersion": "4.0.0"
}
```

### Folder 对象（多层文件夹）

```json
{
  "id": "LZUR2F1JZI3PV",
  "name": "AIGC",
  "description": "",
  "children": [ Folder, ... ],   // 子文件夹，任意深度；数组顺序 = 显示顺序
  "modificationTime": 1723694275495,
  "tags": [],                    // 文件夹自身的标签（字符串数组）
  "password": "",                // 加密文件夹的密码，见下
  "passwordTips": "",
  "coverId": "<ITEM_ID>",        // 可选：封面条目 id（观察到 27/130）
  "orderBy": "BTIME",            // 可选：排序字段，观察到 BTIME / NAME / MTIME
  "sortIncrease": true,          // 可选：与 orderBy 同时出现，true=升序
  "iconColor": "red"             // 可选：文件夹颜色 red/orange/yellow/green/aqua/blue/purple/pink（本库未出现，按 Eagle 约定；Magpie 读写此字段）
}
```

- 文件夹层级**只通过 `children` 嵌套表示**，没有 parentId 字段。父子关系需要遍历树得到。
- `password` 是**明文密码的 Base64 编码**（不是哈希），没有真正的加密作用；空字符串表示未加密。子文件夹继承父文件夹的锁定状态（推测，由 UI 实现）。
- 文件夹里有哪些素材，并不存在文件夹对象中，而是由条目的 `folders` 字段反向指定。

## 5. 条目 `images/<ID>.info/metadata.json`

```json
{
  "id": "LZUQQ1UF05YG0",
  "name": "511760126.446002",          // 显示名，不含扩展名
  "size": 811680,                      // 字节
  "btime": 1718845690647,              // 文件创建时间
  "mtime": 1718845690647,              // 文件修改时间
  "ext": "jpg",                        // 小写，无点
  "tags": ["原神"],                    // 标签：纯字符串数组
  "folders": ["LZUR1IJM1UOY2"],        // 所属文件夹 id，可为 0 个或多个
  "isDeleted": false,                  // true = 在废纸篓中（文件仍保留）
  "url": "",                           // 来源网址
  "annotation": "",                    // 备注
  "modificationTime": 1723693698534,   // 加入库/元数据修改时间
  "lastModified": 1723694267503,       // 与 mtime.json 中的值一致
  "width": 3000, "height": 1814,       // 像素（非图片类可能缺失）
  "palettes": [                        // 主色，按 ratio 降序
    { "color": [69,75,69], "ratio": 39, "$$hashKey": "object:161759" }
  ]
}
```

### 可选字段（观察到的）

| 字段 | 出现次数 | 说明 |
|---|---|---|
| `noThumbnail` | 424 | true 时没有 `_thumbnail.png`，直接用原图显示（小图、svg 等） |
| `removeThumbnail` | 12 | 与 noThumbnail 同出现于 svg，表示缩略图被删除 |
| `noPreview` | 3 | 无法预览的格式 |
| `deletedTime` | 68 | 移入废纸篓的时间 |
| `star` | 1 | 评分 1–5 |
| `duration` | 23 | 视频时长（秒，浮点） |
| `resolutionWidth` / `resolutionHeight` | 23 | 视频分辨率 |
| `text` | 2 | txt 文件的文本内容摘要（前若干字符） |
| `ocr` | 114 | `{"done": "", "text": ""}` |
| `detection` | 114 | `{"done": "", "objects": []}` 物体识别结果 |

说明：
- `palettes[].$$hashKey` 是 AngularJS 的残留字段，读取时忽略；写入时可以不写。
- 文件夹内 0 个 `folders` 的条目 = 「未分类」。
- 本库条目扩展名分布：png 1028, jpg 1016, webp 257, mp4 24, svg 12, gif 4, txt 2, heic/zip/sh/afdesign 各 1 —— 即任意文件都可以入库。

### `.info` 目录中的文件

- 原文件：`<name>.<ext>`，文件名 = `name` + `.` + `ext`（name 可含中文、空格、全角符号、方括号）。
- 缩略图：`<name>_thumbnail.png`，始终是 png，可选。
- 找原文件最稳妥的办法：在目录中找不是 `metadata.json`、不以 `_thumbnail.png` 结尾的那个文件（防止 name 被改过但文件名没变）。

## 6. `tags.json`

```json
{ "historyTags": ["Figure", "原神", ...], "starredTags": [] }
```
仅是 UI 用的最近使用/星标列表，**不是标签的权威来源**。

## 7. `mtime.json`

```json
{ "LZUQQWE7Q8NM8": 1723693740683, ..., "all": 2347 }
```
- 键为条目 id，值等于该条目的 `lastModified`；特殊键 `"all"` 为条目总数。
- 用途：快速判断哪些条目需要重新读取。注意本库中有 2330 个 id 键而条目有 2347 个——**这个索引可能不完整，不能当权威数据**，只作缓存提示。

## 8. `backup/`

库级 `metadata.json` 的完整快照（结构完全相同），文件名 `backup-YYYY-MM-DD HH.MM.SS.mmm.json`，本库约 100 份。条目元数据不备份。

## 9. 兼容实现建议

1. **读**：加载 `metadata.json` → 建 folderId→folder/parent 映射；并行读取全部条目 metadata；汇总标签。
2. **写**：每次修改只重写受影响的文件；先写临时文件再 rename，保证原子性。修改条目后同步更新 `lastModified` 和 `mtime.json`；修改文件夹树后更新顶层 `modificationTime`，可选写一份 backup。
3. **删除**：先软删除（`isDeleted: true` + `deletedTime`），清空废纸篓时再删除整个 `.info` 目录。
4. **未知字段原样保留**：读入后写回时保留不认识的键，避免和 Eagle 本体互相破坏数据。
5. **并发**：Eagle 运行时不要同时写同一个库（Eagle 有内存缓存，会覆盖外部修改）。
6. **待确认**：`smartFolders`、`quickAccess`、`tagsGroups`、`actions.json`、`saved-filters.json` 在本库中都为空，结构需要在 Eagle 中创建样例后再补充。

## 10. Magpie 扩展：`.magpie/index/`

Magpie 向下兼容 Eagle，同时在库目录里维护自己的索引来提速（Eagle 会忽略这个目录）。**索引只放在库里，和库在一起**；本机只缓存缩略图。

```
.magpie/index/
├── 1791681680524-92cb9bb6.json    # 分段：<13 位毫秒时间戳>-<随机串>.json
└── ...
```

每个分段：
```json
{ "version": 1, "items": [ 精简后的条目 metadata, ... ] }
```

- 每个条目只保留：`id name ext tags folders isDeleted url annotation width height size btime mtime modificationTime lastModified noThumbnail star deletedTime`，以及最多 8 个 `palettes`（只含 `color`、`ratio`）。
- **读取**：按文件名排序依次合并，同一 id 后写的覆盖先写的。
- **写入**：只追加新分段（原子写），从不原地修改，因此放在网络盘上安全，多台电脑同时写也不冲突。建索引时每读约 2000 条写一个分段。
- **合并**：分段超过 20 个（或刚建完索引）时，把全部条目写成一个新分段，再删掉文件名时间戳早于合并时刻的旧分段。
- **完整性**：不记录标记；`mtime.json` 中每个 id 都在索引里即为完整。`lastModified` 与 `mtime.json` 不一致的条目重新读取。
- 索引不是权威数据：Eagle 的 `images/*.info/metadata.json` 才是。索引可以随时删除重建。
- `version` 不匹配的分段会被忽略。更早版本留下的 `.openview/index.json` 已不再使用，可以删除。本软件旧名 OpenView，索引目录原为 `.openview/`，打开库时两个目录的分段一起读（按文件名时间戳合并），下次合并快照时写进 `.magpie/` 并删掉 `.openview/`。
