# Codex Rate Limit Guard

Windows PowerShell supervisor for Codex CLI. It detects configurable transient HTTP errors, waits
with exponential backoff, and resumes the most recent Codex session. It does not kill the process
tree by default.

## 中文

### 功能

- 监控通过脚本启动的 `codex exec` 任务
- 默认识别 `429,500,502,503,504`
- 错误编号、最大重试次数、等待时间都可以手动输入或通过参数设置
- **无人值守模式**：使用 `-NoPrompt` 后不询问任何参数，直接按配置自动等待、重试并恢复任务，适合脚本、计划任务和长时间运行
- 支持指数退避和最大等待时间
- 429/500 后自动执行 `codex exec resume --last`
- 默认不主动终止 Codex 或子进程
- 可选 `-KillProcessTree` 处理真正卡死的任务

### 两种运行模式

| 模式 | 是否询问参数 | 启动方式 |
| --- | --- | --- |
| 交互式 | 会询问错误编号、重试次数和等待时间 | 不传 `-NoPrompt` |
| **无人值守** | 不询问，直接使用命令行参数或默认值 | 传入 **`-NoPrompt`** |

无人值守模式的最短命令：

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -NoPrompt -- exec "继续完成这个任务"
```

`-NoPrompt` 就是无人值守模式开关。它是 CLI 参数，不会显示为 Codex App 插件页中的
按钮或开关。

### 安装

在 Codex CLI 中添加个人 marketplace，然后安装插件：

```powershell
codex plugin add codex-rate-limit-guard@personal
```

### 交互式使用

直接运行后，脚本会依次询问错误编号、重试次数和等待时间：

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -- exec "继续完成这个任务并运行测试"
```

默认提示：

```text
Retry error codes [429,500,502,503,504]:
Maximum retries [8]:
Initial cooldown seconds [60]:
```

### 参数化使用

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -ErrorCodes "429,500" `
  -MaxRetries 20 `
  -CooldownSeconds 60 `
  -MaxCooldownSeconds 900 `
  -- exec -C "D:\repo" "继续完成这个任务"
```

### 无人值守模式

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -NoPrompt `
  -ErrorCodes "429,500,502,503,504" `
  -MaxRetries 20 `
  -CooldownSeconds 60 `
  -MaxCooldownSeconds 900 `
  -- exec --json "继续完成这个任务并运行测试"
```

### 参数说明

| 参数 | 说明 |
| --- | --- |
| `-ErrorCodes` | 逗号分隔的 HTTP 状态码，范围 `100-599` |
| `-MaxRetries` | 最大重试次数；`0` 表示不重试 |
| `-CooldownSeconds` | 第一次等待秒数 |
| `-MaxCooldownSeconds` | 单次等待的最大秒数 |
| `-NoPrompt` | 不询问，完全使用参数或默认值 |
| `-KillProcessTree` | 检测到错误后强制终止 Codex 进程树，默认关闭 |
| `-CodexPath` | Codex 可执行文件路径，默认是 `codex` |

### 重要限制

这是 CLI 外部监督器。Codex App 插件不能拦截 App 当前会话的内部模型 HTTP 响应，因此本
项目不能透明接管已经在桌面 App 中运行的对话。要获得自动恢复效果，请通过本脚本启动
`codex exec`。

## English

### Features

- Supervises Codex CLI `codex exec` runs
- Retries configurable transient HTTP errors; defaults to `429,500,502,503,504`
- Lets users set error codes, retry count, and cooldown interactively or by flags
- **Unattended mode**: `-NoPrompt` disables all questions and automatically waits, retries, and resumes using configured values; suitable for scripts and long-running tasks
- Uses exponential backoff with a maximum delay
- Resumes the latest session with `codex exec resume --last`
- Does not terminate Codex or child processes by default
- Provides optional `-KillProcessTree` for genuinely stuck runs

### Run modes

| Mode | Prompts for settings | How to enable |
| --- | --- | --- |
| Interactive | Yes | Omit `-NoPrompt` |
| **Unattended** | No | Pass **`-NoPrompt`** |

Minimal unattended command:

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -NoPrompt -- exec "Continue the task"
```

### Installation

Install from the personal marketplace:

```powershell
codex plugin add codex-rate-limit-guard@personal
```

### Interactive usage

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -- exec "Continue the task and run tests"
```

The script asks for retryable status codes, maximum retries, and the initial cooldown. Press Enter
to accept the defaults.

### Non-interactive usage

```powershell
& "$HOME\plugins\codex-rate-limit-guard\scripts\codex-rate-limit-guard.ps1" `
  -NoPrompt `
  -ErrorCodes "429,500,502,503,504" `
  -MaxRetries 20 `
  -CooldownSeconds 60 `
  -MaxCooldownSeconds 900 `
  -- exec --json "Continue the task and run tests"
```

### Safety and scope

Only the Codex process started by this script is supervised. Non-transient errors are returned
without retrying. The retry loop operates at the Codex session boundary and resumes the latest
session instead of replaying individual tool calls.

## Development

Validate the plugin manifest:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" `
  "$HOME\plugins\codex-rate-limit-guard"
```

License: MIT.
