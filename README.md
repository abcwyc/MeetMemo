<div align="center">
  <img src="https://github.com/user-attachments/assets/309577e8-94db-431f-b8df-a53a763b4c87" alt="MeetMemo Logo" width="80" height="80">

  <h3 align="center">MeetMemo</h3>

  <p align="center">
    免费、开源、运行在本地的 macOS AI 会议纪要助手
    <br />
    <a href="https://file.348580.xyz/drive/MeetMemo%202026-05-05%2023-02-46.zip">下载 macOS 15+ 版本</a>
  </p>
</div>

## 简介

MeetMemo 是一款原生 macOS AI 会议记录工具。它可以同时捕获麦克风和系统音频，实时生成会议转录，并基于会议原文、会前资料和自定义模板生成结构化纪要。

它适合日常会议、站会、1:1、客户访谈、需求评审、招聘面试等场景。所有会议数据保存在本机，语音识别和大模型服务由用户自行配置。
![](https://file.348580.xyz/2026/05/8670f67b097879765e8a8b24db0be2cc.png)
![](https://file.348580.xyz/2026/05/e70077cdda256e13aee01b2da6b03695.png)


## 核心特色

- **双路音频录制**：同时录制麦克风与系统音频，分别标记自己和会议中其他人的发言。
- **实时转录**：录制过程中持续接收流式语音识别结果，会议结束后保留完整转录原文。
- **音频文件导入**：支持导入音频或视频文件，并使用已配置的语音识别服务生成转录。
- **AI 智能纪要**：基于转录内容流式生成 Markdown 纪要，并在空标题时自动生成会议标题。
- **会前资料补充**：可为单场会议添加手动背景信息或文件上下文，让生成结果更贴近业务语境。
- **模板化输出**：内置标准会议、一对一沟通、客户需求访谈、需求提报、招聘面试、每日站会、周团队会议等模板，也支持创建和管理自定义模板。
- **可配置模型服务**：语音识别当前使用豆包流式语音识别；纪要生成支持 Anthropic Messages API，以及 OpenAI 兼容的 Chat Completions API。
- **本地数据管理**：会议、摘要和模板以 JSON 文件保存在本机 Documents 目录；服务凭据保存在 macOS Keychain。
- **会议列表管理**：支持搜索、重命名、删除会议，并可一键复制会前资料、转录原文或智能纪要。
- **中英文界面与外观设置**：支持中文/英文界面切换，以及跟随系统、浅色、深色外观。

## 如何使用

### 1. 安装并打开

下载最新的 [MeetMemo.dmg](https://file.348580.xyz/drive/MeetMemo%202026-05-05%2023-02-46.zip)，安装后打开应用。

首次启动会进入引导页，需要完成权限和服务配置。你也可以稍后在「设置」中重新配置。

### 2. 授权录音权限

MeetMemo 需要以下权限：

- **麦克风权限**：用于转录你在会议中说的话。
- **系统录音权限**：用于捕获线上会议、播放器或其他应用中的声音。

如果授权失败，请到「系统设置 > 隐私与安全性」中为 MeetMemo 开启对应权限。

### 3. 配置语音识别服务

在「服务配置」或「设置 > 模型」中填写：

- `APP ID`
- `Access Token`

当前实现使用豆包流式语音识别。相关凭据可在火山引擎控制台获取，应用内也提供配置[教程入口](https://file.348580.xyz/2026/04/eb299b186e0b531ffebceb9141eaf2fb.html)。


### 4. 配置 LLM 服务

在「LLM 配置」中填写：

- `API Key`
- `Base URL`
- `Model Name`

默认 `Base URL` 是 `https://api.anthropic.com`。当地址为 Anthropic 时，MeetMemo 会使用 Messages API；其他地址会按 OpenAI 兼容 Chat Completions API 调用。

常见示例：

```text
Anthropic: https://api.anthropic.com
OpenAI-compatible: https://api.example.com/v1
Volcengine Ark: https://ark.cn-beijing.volces.com/api/v3
```

填写后可以点击「测试连接」确认配置是否可用。

### 5. 创建会议并录制

1. 点击侧边栏「创建会议」。
2. 在会议详情页点击「开始录制」。
3. 会议过程中查看「转录原文」。
4. 结束后点击「生成纪要」，选择合适模板生成智能纪要。

如果会议中途需要继续补录，可以再次点击「继续录制」。

### 6. 导入已有音频

点击侧边栏「导入」，选择音频或视频文件。MeetMemo 会读取文件音频，转写为一场新的会议记录。

### 7. 使用会前资料和模板

在「会前资料」中添加背景信息、补充说明或文件内容。这些内容会和转录一起进入纪要生成流程。

在「设置 > 提示词 > 管理模板」中可以查看内置模板、创建自定义模板，并为不同会议选择不同输出结构。

### 8. 管理和复制结果

会议保存在侧边栏中，可搜索、重命名或删除。打开任意会议后，可以复制当前标签页内容，包括会前资料、转录原文和智能纪要。

## 数据与隐私

- 会议文件、会议摘要和模板保存在本机 Documents 目录下的 `Meetings/`、`MeetingSummaries/`、`Templates/`。
- STT 和 LLM 的 API Key、Token、Base URL、模型名保存在 macOS Keychain。
- MeetMemo 本身不提供云端账号系统，也不会把会议数据同步到项目自有服务器。
- 语音识别和纪要生成会发送必要的音频或文本到你配置的第三方服务，请根据你的组织合规要求选择服务商。

## 本地开发

使用 Xcode 打开 `MeetMemo.xcodeproj`，选择 `MeetMemo` scheme 后构建运行。

命令行构建：

```bash
xcodebuild -project MeetMemo.xcodeproj -scheme MeetMemo -configuration Debug build
```

> 修改原生 App 后请构建验证；仅构建即可，不需要在命令行启动应用。

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

脚本会清理构建 Release 版本，并创建签名后的 DMG 文件。

### 创建 GitHub Release

1. 打开 [GitHub Releases](https://github.com/abcwyc/MeetMemo/releases)。
2. 创建新 release，tag 使用 `v版本号`，例如 `v1.0.1`。
3. 上传 `releases/` 目录下生成的 DMG。
4. 生成并补充 release notes。

## 许可证

MeetMemo 是开源项目，具体许可见 [LICENSE](LICENSE)。
