# Photo Atlas

**面向 Apple Photos 的 macOS 本地 AI 照片管理应用**  
**A native macOS app for organizing Apple Photos with local AI**

Photo Atlas 使用本地视觉模型和系统文字识别，为照片生成说明和关键词，并可自动写入 Apple Photos。应用提供可暂停的后台队列、处理记录和写入回读。照片内容通过本机 Ollama 服务处理。

Photo Atlas uses a local vision model and system text recognition to generate captions and keywords and can write them to Apple Photos. It includes a resumable background queue, processing history, and write verification. Photo content is processed through a local Ollama service.

[中文说明](#中文说明) · [English](#english)

## 中文说明

### 功能

- 本地 AI 生成中文照片说明和关键词，包含图片中的可见文字及敏感内容。
- 自动扫描并写入 Apple Photos，支持暂停、继续以及写入后的回读核验。
- 保存原始元数据快照，支持对具有回执的写入撤销新增关键词。
- 从本地照片索引读取已命名的人物和已有地点候选，可在照片浏览中追加。
- 按需获取 iCloud 照片预览，在处理记录中搜索和筛选。

### 系统与依赖

- macOS 13 或更新版本，Apple Silicon 推荐。
- Xcode Command Line Tools 和 Swift 6。
- 已运行的 Ollama，以及模型 `qwen3-vl:4b-instruct`。
- Python 3 虚拟环境与 `osxphotos`，用于读取人物及地点候选。当前版本使用 `~/AI-Photo-Manager/.venv/bin/python`，并读取默认的系统照片图库。可在该路径创建环境并安装 `osxphotos==0.78.0`。

```bash
xcode-select --install
ollama pull qwen3-vl:4b-instruct
python3 -m venv ~/AI-Photo-Manager/.venv
~/AI-Photo-Manager/.venv/bin/python -m pip install osxphotos==0.78.0
Scripts/build-app.sh
```

构建完成后打开 `build/Photo Atlas 0.4.5.app`，按系统提示授权照片访问与照片自动化。在「智能扫描」选择范围后启动，已有队列可点击「继续已有队列」。也可运行 `Scripts/package-dmg.sh` 制作安装镜像。

### 后台运行与当前限制

扫描和监护进程声明为用户启动的系统活动，并在扫描时防止系统空闲睡眠。监护进程会重启长时间无响应的处理进程；识别和索引任务会重试，不确定的照片写入会先核验。重启电脑后，需要打开应用恢复之前的队列。长时间无人值守的连续运行仍需进一步验证。

### 数据与使用

AI 结果和照片原始元数据快照存放在当前用户的 `~/Library/Application Support/Photo Atlas` 中。应用可以将识别出的文字及敏感内容写入照片关键词。人物与地点索引依赖照片图库的内部结构，系统更新可能影响兼容性。应用使用本地临时签名，macOS 更新权限或更换构建后可能再次请求授权。此版本仍处于开发阶段，建议先用少量照片验证处理效果。

## English

### Features

- Generate Chinese captions and keywords with a local vision model, including visible text and sensitive content.
- Scan and write to Apple Photos automatically, pause and resume the queue, and verify writes by reading metadata back.
- Keep original metadata snapshots and undo added keywords when a write receipt is available.
- Read named-person and existing location candidates from the local Photos index and append them from the photo browser.
- Fetch iCloud photo previews as needed and search or filter processing records.

### Requirements and setup

- macOS 13 or later, with Apple Silicon recommended.
- Xcode Command Line Tools and Swift 6.
- A running Ollama service with `qwen3-vl:4b-instruct` installed.
- A Python 3 virtual environment with `osxphotos` for person and location candidates. The current version uses `~/AI-Photo-Manager/.venv/bin/python` and the default system Photos library. Create that environment and install `osxphotos==0.78.0`.

```bash
xcode-select --install
ollama pull qwen3-vl:4b-instruct
python3 -m venv ~/AI-Photo-Manager/.venv
~/AI-Photo-Manager/.venv/bin/python -m pip install osxphotos==0.78.0
Scripts/build-app.sh
```

Open `build/Photo Atlas 0.4.5.app` and grant Photos and automation access when prompted. Choose a scan scope in the scan view, or resume an existing queue. Run `Scripts/package-dmg.sh` to create a disk image.

### Background operation and current limits

The scan and supervisor processes declare a user-initiated activity and prevent idle system sleep while scanning. The supervisor restarts an unresponsive worker; interrupted recognition and indexing tasks are retried, while uncertain photo writes are verified first. After a computer restart, open the app to resume the queue. Extended unattended operation still requires further validation.

### Data and usage

AI results and original metadata snapshots are stored in the current user's `~/Library/Application Support/Photo Atlas` directory. The app can write recognized text and sensitive content into photo keywords. Person and location indexing relies on internal Photos library structures and can be affected by system updates. Builds use ad hoc signing, so macOS may request permissions again after an update. This project is under development. Try a small selection of photos first.

## Tests / 测试

```bash
swift test
python3 -m unittest discover -s Tests
```
