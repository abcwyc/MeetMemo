<div align="center">
  <img src="https://file.348580.xyz/{year}/{month}/{md5}.{extName}/meetmemo-Q2 (2).png" alt="MeetMemo Logo" width="80" height="80">


  <h3 align="center">MeetMemo</h3>

  <p align="center">
    免费、源码公开、运行在本地的 macOS AI 会议纪要助手
    <br />
    <a href="https://github.com/abcwyc/MeetMemo/releases">下载 macOS 26+ 版本</a>
  </p>

</div>

## 简介

MeetMemo 是一款原生 macOS AI 会议记录工具。它同时捕获麦克风和系统音频，在本机实时生成会议转录，并结合会前资料和自定义模板，调用你自己配置的大模型生成结构化纪要。

适用于日常会议、站会、1on1、客户访谈、需求评审、招聘面试等场景。所有会议数据保存在本机，语音识别完全离线运行，纪要生成所用的大模型服务由你自行配置——MeetMemo 不提供云端账号，也不会把你的会议数据同步到任何项目方服务器。

MeetMemo ：

- **本地语音识别**：提供 macOS SpeechAnalyzer 与本地 SenseVoice（sherpa-onnx）两种引擎完成实时转录，减少对外部 STT 服务的依赖；LLM 端支持配置任意 OpenAI 兼容接口的模型（含 Anthropic），模型自选。
- **说话人识别（Speaker Diarization）**：选用 SenseVoice 引擎时，在双路录音基础上进一步区分发言人，纪要直接标注"谁说了什么"。
- **会前上下文注入**：单场会议可预加载项目背景、专有名词或参考文档，生成纪要时带入业务语境。
- **行动项落地**：纪要中的行动项可直接写入系统「提醒事项」，让会议结论转化为可跟踪的任务。
- **本地化 UI**：中英文界面一键切换，支持 macOS 浅色 / 深色外观自适应。



- 转录原文

![](https://file.348580.xyz/2026/05/780e4b22ec10e6cd1ebaa57582939546.png)
- 会议纪要

![](https://file.348580.xyz/{year}/{month}/{md5}.{extName}/123456.png)

- 自定义会议总结提示词

![](https://file.348580.xyz/2026/05/d0ddc376505f59e3aaadb8a9526ad553.png)

## 核心特色

- **双路音频录制**：同时录制麦克风与系统音频，分别标记"自己"和"会议中的其他人"。
- **实时转录**：录制过程中持续接收流式语音识别结果，会议结束后保留完整转录原文，支持中途继续补录。
- **本地双引擎语音识别**：转录完全在本机运行，无需 STT API Key。可在「设置 > 模型」中选择：
  - **macOS 内置（SpeechAnalyzer）**：开箱即用，首次使用可能需要下载系统语音模型。
  - **本地 SenseVoice（sherpa-onnx）**：基于 SenseVoice-Small + Silero VAD + CAM++ 声纹，支持**说话人识别**，纪要可标注"谁说了什么"；首次使用需在设置中下载本地模型。
- **音频文件导入**：支持导入音频或视频文件，转写为一场新的会议记录。
- **AI 智能纪要**：基于转录内容流式生成纪要，支持 Markdown 与结构化两种输出格式，并在标题为空时自动生成会议标题。
- **会前资料补充**：可为单场会议添加背景信息或文件内容，让生成结果更贴合业务语境，减少后期人工校对。
- **行动项与提醒**：从纪要中提取行动项（待办任务），确认后可一键加入 macOS 系统「提醒事项」App。
- **模板化输出**：内置 7 套模板——标准会议、一对一沟通、客户需求访谈、需求提报、招聘面试、每日站会、周团队会议，也支持创建和管理自定义模板。
- **可配置 LLM 服务**：纪要生成支持 Anthropic Messages API，以及任意 OpenAI 兼容的 Chat Completions API（火山方舟、Kimi 等），模型自选。
- **本地数据管理**：会议、摘要和模板以 JSON 文件保存在本机 Documents 目录；LLM 服务凭据保存在 macOS Keychain。
- **会议列表管理**：支持搜索、重命名、删除会议，并可一键复制会前资料、转录原文或智能纪要；支持导出 HTML 纪要。
- **中英文界面与外观设置**：支持中文/英文界面切换，以及跟随系统、浅色、深色外观。



## 系统要求

- macOS **26.0** 及以上。
- 一个可用的大模型服务（Anthropic 或任意 OpenAI 兼容服务）及对应 API Key。

## 如何使用

### 1. 安装并打开

下载最新的 [MeetMemo.dmg](https://github.com/abcwyc/MeetMemo/releases)，安装后打开应用。

首次启动会进入引导页，需要完成权限和服务配置。你也可以稍后在「设置」中重新配置。

### 2. 授权录音权限

MeetMemo 需要以下权限：

- **麦克风权限**：用于转录你在会议中说的话。
- **语音识别权限**：用于调用本机语音识别生成转录。
- **系统录音权限**：用于捕获线上会议、播放器或其他应用中的声音。
- **提醒事项权限（可选）**：用于把会议行动项写入系统「提醒事项」App。

如果授权失败，请到「系统设置 > 隐私与安全性」中为 MeetMemo 开启对应权限。

### 3. 选择并准备语音识别引擎

在引导页或「设置 > 模型」中选择语音识别引擎：

- **macOS 内置（SpeechAnalyzer）**：检查 / 安装系统语音识别模型即可。
- **本地 SenseVoice**：点击下载本地模型；若需要说话人识别，请选择此引擎。

转录在本地运行，无需 STT API Key；首次安装 / 下载模型时可能需要网络。

### 4. 配置 LLM 服务

在「设置 > 模型 > LLM 配置」中填写：

- `API Key`
- `Base URL`
- `Model Name`

默认 `Base URL` 是 `https://api.anthropic.com`。当地址为 Anthropic 时，MeetMemo 会使用 Messages API；其他地址会按 OpenAI 兼容 Chat Completions API 调用。

常见示例：

```text
Anthropic:               https://api.anthropic.com
OpenAI-compatible:       https://api.example.com/v1
火山方舟 Ark:            https://ark.cn-beijing.volces.com/api/v3
火山方舟 Coding Plan:    https://ark.cn-beijing.volces.com/api/coding/v3
Kimi 官方:               https://api.moonshot.cn/v1
```

填写后可以点击「测试连接」确认配置是否可用。

### 5. 创建会议并录制

1. 点击侧边栏「创建会议」。
2. 在会议详情页点击「开始录制」。
3. 会议过程中查看「转录原文」。
4. 结束后点击「生成纪要」，选择合适的模板生成智能纪要。

如果会议中途需要继续补录，可以再次点击「继续录制」。

> 注意：录音过程中无法切换识别引擎，如需切换请先结束当前录音。

### 6. 导入已有音频

点击侧边栏「导入」，选择音频或视频文件。MeetMemo 会读取文件音频，转写为一场新的会议记录。

### 7. 使用会前资料和模板

在「会前资料」中添加背景信息、补充说明或文件内容，这些内容会和转录一起进入纪要生成流程。

在「设置 > 提示词 > 管理模板」中可以查看内置模板、创建自定义模板，并为不同会议选择不同的输出结构。

### 8. 管理结果与行动项

- 会议保存在侧边栏中，可搜索、重命名或删除。
- 打开任意会议后，可以复制当前标签页内容（会前资料、转录原文、智能纪要），或导出 HTML 纪要。
- 从纪要中提取行动项，确认后一键加入系统「提醒事项」App。

## 数据与隐私

- 会议文件、会议摘要和模板保存在本机 Documents 目录下的 `Meetings/`、`MeetingSummaries/`、`Templates/`（沙盒构建下位于应用容器内）。
- LLM 的 API Key、Base URL、模型名保存在 macOS Keychain。
- MeetMemo 不提供云端账号系统，也不会把会议数据同步到项目自有服务器。
- 语音识别在本机离线处理，音频不离开设备；纪要生成会把必要文本发送到你配置的 LLM 服务，请根据你所在组织的合规要求选择服务商。

## 本地开发

使用 Xcode 打开 `MeetMemo.xcodeproj`，选择 `MeetMemo` scheme 后构建运行。

```bash
xcodebuild -project MeetMemo.xcodeproj -scheme MeetMemo -configuration Debug build
```

> 修改原生 App 后请构建验证；仅构建即可，不需要在命令行启动应用。

本地 SenseVoice 引擎依赖 sherpa-onnx 预编译框架，未纳入版本库，请先拉取：

```bash
./scripts/fetch_sherpa_frameworks.sh
```

项目架构说明详见 [`CLAUDE.md`](CLAUDE.md)。

## 发布新版本

发布构建需要 `.env` 中配置 `DEVELOPER_ID`、`APPLE_ID`、`TEAM_ID`、`APP_PASSWORD`。

### 准备

```bash
brew install create-dmg
chmod +x scripts/update_version.sh scripts/build_release.sh
```

### 更新版本号

```bash
./scripts/update_version.sh patch
./scripts/update_version.sh minor
./scripts/update_version.sh major
./scripts/update_version.sh custom 1.2.0
```

### 构建发布包

```bash
./scripts/build_release.sh
```

脚本会清理并构建 Release 版本（arm64 + x86_64 通用二进制），并创建签名后的 DMG 文件。

### 创建 GitHub Release

1. 打开 [GitHub Releases](https://github.com/abcwyc/MeetMemo/releases)。
2. 创建新 release，tag 使用 `v版本号`，例如 `v0.4`。
3. 上传 `releases/` 目录下生成的 DMG。
4. 生成并补充 release notes。

## 贡献

欢迎提交 Issue 和 Pull Request，请遵循 [CONTRIBUTING.md](CONTRIBUTING.md)（含约定式提交规范）。

## 许可证

MeetMemo 采用 [PolyForm Noncommercial License 1.0.0](LICENSE)（非商业许可）发布。

- 允许：个人、学习、研究、教育、慈善、政府等**任何非商业目的**的使用、修改与分发。
- 要求：修改或再分发时，必须保留版权声明（`Required Notice: Copyright (c) 2026 abcwyc`）与本许可证文本。

如需商业授权，请通过仓库 [Issues](https://github.com/abcwyc/MeetMemo/issues) 联系作者。
