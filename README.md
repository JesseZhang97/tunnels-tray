# Tunnels

macOS 菜单栏小工具，用来管理 SSH 本地端口转发（`ssh -L`）。每条隧道一行，点一下就在浏览器打开对应页面。

- 原生 Swift / SwiftUI（`MenuBarExtra`），只用系统框架，无第三方依赖。
- 要求 macOS 14+，Xcode 或 Command Line Tools（Swift 5.9+）。

## 构建与运行

```bash
./scripts/bundle.sh          # swift build -c release，生成 build/Tunnels.app（ad-hoc 签名）
open build/Tunnels.app
```

可选：把 `build/Tunnels.app` 拖进 `/Applications`。

测试（命令拼装、shell 分词、~/.ssh/config 解析、JSON、端口检测）：

```bash
swift test
```

## 每条隧道的字段

| 字段 | 说明 | 默认值 |
|---|---|---|
| Name | 显示名 | 必填 |
| SSH host | `~/.ssh/config` 里的 Host，表单里可下拉选择，也可手填 | 必填 |
| Local port | 本地端口 1–65535 | 必填 |
| Remote host | 远端目标主机 | `127.0.0.1` |
| Remote port | 远端端口 1–65535 | 必填 |
| Bind address | 本地监听地址，留空则用 ssh 默认（localhost） | `127.0.0.1` |
| SSH options | 只放额外参数。表单里用选项列表编辑（选 Key，再填值），也可以展开 "Advanced: raw" 直接改文本 | 空 |
| Note | 备注 | 空 |

实际执行的命令：

```
/usr/bin/ssh -N -T -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -L <bind>:<local>:<remote_host>:<remote_port> <SSH options> <SSH host>
```

`-N -T -o BatchMode=yes` 和三个默认 `-o` 选项每条隧道都会加，不用单独配置。如果某条隧道在 SSH options 里设了同名的 Key（例如 `ServerAliveInterval=60`），就用它的值，不再加默认值。

SSH options 编辑器里的常用 Key：User、Port、IdentityFile（可选文件）、IdentitiesOnly、ProxyJump（可从 ~/.ssh/config 选）、Compression、ConnectTimeout、ServerAliveInterval、ServerAliveCountMax、ExitOnForwardFailure、TCPKeepAlive、StrictHostKeyChecking、LogLevel、IPQoS、AddressFamily、GatewayPorts、ForwardAgent、HostKeyAlias，以及 "Custom…"（自定义 Key 和值）。不是 `-o` 形式的参数（例如 `-C`）原样保留，在 raw 里编辑。

例子：

- NMcloud：SSH host `taiwan-nmcloud`，端口 18317 → 18317，其余用默认值，SSH options 留空。
- magpie：SSH host `contabo`，端口 3430 → 3430，Bind address 留空，SSH options 留空（会额外带上默认选项）。

## 行为

- App 启动时不自动开启任何隧道，全部手动启动；不做开机自启。
- `BatchMode=yes`：只支持密钥 / ssh-agent 登录，不会弹出密码或 host key 确认。第一次连新主机，先在终端里 `ssh <host>` 一次，接受 host key。
- 启动前先检测本地端口能否绑定。被占用时状态变红，并显示占用进程（通过 `lsof`）。
- 状态：绿色 = 已连接（ssh 存活超过 2 秒且端口在监听）；黄色 = 连接中或重连中；灰色 = 已停止；红色 = 出错。
- 意外断开会自动重连，等待 1、2、4、8… 秒，最长 30 秒；连接保持超过 30 秒后重置退避。手动停止不会重连。
- 点 Quit 或 App 收到 SIGTERM / SIGINT / SIGHUP 时，会结束所有 ssh 子进程。

## 界面

- 顶部：标题 Tunnels，右边 All 开关一键启动或停止全部。
- 每行：蓝色本地端口、名字、状态点和运行时长、`ssh_host → remote_host:remote_port`。
- 行内出错或重连时，在副标题下用一行红字显示最近一次错误（过长会截断，鼠标停留可看全文）。点行本身没有动作。
- 鼠标悬停：在浏览器打开 `http://<bind>:<local_port>`（bind 为 `0.0.0.0`、`*` 或空时用 `127.0.0.1`）、启动/停止、复制 ssh 命令、编辑、删除（删除要在行内再点一次红色 Delete 确认）。
- 底部：+ Add、Settings（导入/导出 JSON、在 Finder 中显示、重新读取 ~/.ssh/config）、Quit。

## 配置文件

`~/Library/Application Support/Tunnels/tunnels.json`，是一个 JSON 数组，键名用 snake_case：

```json
[
  {
    "id": "6F1C…",
    "name": "NMcloud",
    "ssh_host": "taiwan-nmcloud",
    "local_port": 18317,
    "remote_host": "127.0.0.1",
    "remote_port": 18317,
    "bind_address": "127.0.0.1",
    "ssh_options": "",
    "note": ""
  }
]
```

手写导入时 `id` 可省略，`remote_host`、`bind_address`、`ssh_options`、`note` 省略时用默认值，端口也可以写成字符串。导入时同 `id` 的条目会被替换，其余追加。旧版本把默认选项写在 `ssh_options` 里，读取时会自动去掉与内置默认值完全相同的项（以及 `-N`、`-T`），并写回文件。文件读不出来时，App 会把它改名为 `tunnels.corrupt-<时间戳>.json` 保留，不会覆盖。

## 代码结构

```
Sources/TunnelsCore/   纯逻辑，可测试
  Tunnel.swift         数据模型、表单草稿与校验
  ShellWords.swift     shell 风格分词与转义
  SSHCommand.swift     拼装 ssh 参数和可复制的命令行
  SSHOptions.swift     -o 选项的解析/生成/校验、内置默认值、迁移
  SSHConfig.swift      解析 ~/.ssh/config 的 Host（跳过通配符，跟随 Include）
  TunnelStore.swift    JSON 读写
  PortCheck.swift      bind 检测端口是否空闲
Sources/Tunnels/       App
  TunnelsApp.swift     MenuBarExtra 入口、退出和信号处理
  TunnelManager.swift  ssh 子进程、状态、自动重连
  PopoverView.swift    弹窗
  TunnelRow.swift      每一行
  TunnelFormView.swift 添加/编辑表单
  SSHOptionsEditor.swift SSH options 结构化编辑器
  SettingsView.swift   设置窗口
  Windows.swift        打开普通 NSWindow
scripts/bundle.sh      打包 .app
Support/Info.plist     LSUIElement=true，com.jesse.tunnels
```

## 已知限制

- App 被强制杀掉（`kill -9`）或崩溃时，ssh 子进程会残留，需要手动结束。
- Bind address 写主机名（不是 IP）时跳过端口预检，交给 ssh 判断。
- `~/.ssh/config` 里的 `Match` 块不解析。
