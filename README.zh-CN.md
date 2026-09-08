# VPS Guard

一个以“**先保证你不会被锁在 VPS 外面**”为核心设计目标的 Debian/Ubuntu 安全加固与长期运维工具。

当前版本：**0.2.0**。

## 三个核心能力

### 1. Safe Change Engine

SSH 和 UFW 属于高风险修改。VPS Guard 不再只是“备份以后让你自己 rollback”，而是先创建事务，再启动 systemd 自动回滚计时器。

```bash
sudo vpsg ssh apply --yes
sudo vpsg firewall apply --yes
```

默认 180 秒内没有确认，就自动恢复修改前状态：

```bash
vpsg safe status
sudo vpsg commit
```

也可以指定时间：

```bash
sudo vpsg safe firewall apply --timeout 300 --yes
```

推荐流程：保持当前 SSH 窗口不关 → 应用修改 → 新开一个 SSH 窗口重新连接 → 确认服务正常 → `sudo vpsg commit`。

回滚使用持久 systemd timer，和发起操作的 SSH Shell 独立；即使 SSH 连接断开，计时器仍继续运行。定时器使用绝对时间和 `Persistent=true`，如果服务器在截止时间前重启并错过截止时间，systemd 恢复后仍会执行回滚任务。

### 2. Exposure Analyzer

```bash
vpsg exposure scan
vpsg exposure explain 3306
```

它会把这些信息放到同一个视图：

- TCP/UDP 监听端口；
- 监听地址是 loopback、私网、指定地址还是 `0.0.0.0/::`；
- 监听进程；
- UFW 状态；
- Docker 发布端口及容器名称。

这样可以发现“UFW 看起来没问题，但 Docker 把服务发布到了所有网卡”等容易忽略的情况。

注意：工具将 `NET-FACING` / `DOCKER-PUB` 定义为“具备外部接入条件的监听”，不会武断宣称一定能从公网访问，因为云厂商安全组、NAT、nftables/iptables、上游防火墙仍可能拦截。

### 3. Baseline & Drift

配置完成、确认服务器处于可信状态后：

```bash
sudo vpsg baseline create
```

以后检查：

```bash
sudo vpsg drift scan
```

会跟踪：

- 监听端口；
- Docker 发布端口和容器状态；
- 登录用户；
- sudo 权限；
- `authorized_keys` 的哈希和行数；
- SSH 有效配置；
- 防火墙；
- systemd enabled 服务；
- cron 文件哈希；
- 关键网络/安全 sysctl。

确认变化合法后更新基线：

```bash
sudo vpsg baseline create default --force
```

需要用于自动化检查时：

```bash
sudo vpsg drift scan default --strict
```

检测到漂移时退出码为 `3`。

## 其他功能

- SSH 安全配置
- UFW
- Fail2Ban
- BBR
- Swap
- Docker
- 系统状态与 `doctor`
- 模块化 CLI
- 日志、备份、验证与回滚

## 安装

```bash
sudo ./install.sh
vpsg --version
vpsg doctor
```

## 常用命令

```bash
vpsg status
vpsg exposure scan
sudo vpsg baseline create
sudo vpsg drift scan

vpsg ssh plan
sudo vpsg ssh apply --yes
vpsg safe status
sudo vpsg commit

vpsg firewall plan
sudo vpsg firewall apply --yes
```

## 安全边界

VPS Guard 不能替代：

- 云厂商安全组；
- VPS 提供商的 Web/VNC/Serial Console；
- 主机快照与异地备份；
- 专业入侵检测；
- 对 nftables/iptables 所有自定义规则的完整形式化分析。

生产环境使用前建议先阅读 [docs/security-model.md](docs/security-model.md)，并在带快照/控制台的测试 VPS 验证。

## License

MIT
