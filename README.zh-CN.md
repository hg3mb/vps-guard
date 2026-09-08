# VPS Guard

**安全优先、对新手友好的 Debian / Ubuntu VPS 运维工具。**

VPS Guard 不只是“一键安装一堆东西”。它的目标是让普通 VPS 用户能做到三件更重要的事：

1. **改 SSH / 防火墙时，不小心失联也能自动恢复。**
2. **知道服务器实际上向外暴露了什么，而不是只看 UFW 表面状态。**
3. **知道服务器从上次确认安全以后发生了哪些变化。**

当前版本：**v0.3.0**

## 新手直接用

安装后直接运行：

```bash
vpsg
```

会看到中文菜单，把功能按“安全与变化 / 日常管理”分组，不要求先记命令。

常用入口：

```bash
vpsg status                 # VPS 仪表盘
vpsg doctor                 # 只读体检
vpsg exposure scan          # 看公网暴露与风险
sudo vpsg baseline create   # 建立可信安全基线
sudo vpsg drift scan        # 看之后发生了什么变化
```

## 三个核心创新

### Safe Change Engine 2.0

SSH / UFW 修改会先创建恢复事务，并启动独立的 systemd 倒计时。如果管理员因为配置错误失去 SSH 连接，**不需要再登录服务器执行 rollback**；到时间后服务器自己恢复。

```bash
sudo vpsg ssh apply --yes
sudo vpsg firewall apply --yes
```

流程：

```text
修改前自检
  ↓
保存恢复点
  ↓
启动失联回滚计时器
  ↓
应用修改
  ↓
修改后再次验证
  ↓
新开 SSH 窗口测试
  ↓
sudo vpsg commit
```

如果不 commit，则自动恢复。

```bash
vpsg safe status
vpsg safe history
vpsg safe show <transaction-id>
sudo vpsg safe rollback
```

v0.3.0 还增加了：

- 修改前 SSH / 端口检查；
- 修改后服务验证；
- commit 前再次验证；
- 事务历史；
- 每个事务的事件记录；
- 自动回滚日志。

SSH 还支持更严格、但带保护的选项：

```bash
sudo vpsg ssh apply --disable-password --yes
sudo vpsg ssh apply --root-key-only --yes
```

如果当前管理员没有检测到 `authorized_keys`，VPS Guard 会拒绝关闭密码登录。

### Exposure Analyzer 2.0

普通端口列表只告诉你“3306 在监听”。VPS Guard 尝试进一步回答：**它是什么、为什么值得关注、Docker 有没有发布、UFW 怎么看、应该怎么办。**

```bash
vpsg exposure scan
vpsg exposure explain 3306
vpsg exposure json
```

示例：

```text
PORT   RISK      SERVICE       SCOPE      REASON
22     MEDIUM    SSH           wildcard   SSH 是必要管理入口，请确保密钥认证和防爆破
80     LOW       Web           wildcard   常见 Web 服务端口
3306   HIGH      MySQL         wildcard   数据库/管理类端口通常应限制来源
6379   CRITICAL  Redis         wildcard   常见敏感服务不应直接暴露公网
2375   CRITICAL  Docker API    wildcard   常见敏感服务不应直接暴露公网
```

同时关联：

- TCP / UDP listener；
- `0.0.0.0` / `::` / loopback / 私网绑定；
- UFW；
- Docker published ports；
- 常见服务类型；
- 风险等级；
- 人能看懂的修复建议。

它不会假装知道云厂商安全组状态，因此“本机具备公网接入条件”和“互联网一定可以访问”会明确区分。

### Baseline & Drift 2.0

服务器配置完成并确认可信后：

```bash
sudo vpsg baseline create
```

以后：

```bash
sudo vpsg drift scan
```

它会检查：

- 新增/消失的监听端口；
- Docker 端口和容器变化；
- 用户账户；
- sudo 权限；
- `authorized_keys` 哈希与数量；
- SSH 有效配置；
- 防火墙；
- systemd enabled 服务；
- cron；
- 关键 sysctl。

输出不仅告诉你“哪个文件变了”，还会解释为什么值得关注，并把每次报告保存在本机：

```bash
vpsg drift history
vpsg drift show <report>
```

## 基础运维能力

### 用户与 sudo

```bash
vpsg users list
sudo vpsg users add deploy --sudo
sudo vpsg users sudo deploy disable
sudo vpsg users lock deploy
sudo vpsg users unlock deploy
```

创建用户默认不设置可登录密码，建议随后导入 SSH key：

```bash
sudo vpsg ssh import-github <GitHub用户名> --user deploy
```

### UFW

```bash
vpsg firewall status
sudo vpsg firewall apply --yes
sudo vpsg firewall web
sudo vpsg firewall allow 8080 tcp
sudo vpsg firewall deny 3306 tcp
```

VPS Guard 会拒绝直接 deny / 删除当前 SSH 端口规则。

### Fail2Ban

```bash
sudo vpsg fail2ban apply --yes
vpsg fail2ban banned
sudo vpsg fail2ban unban 203.0.113.10
vpsg fail2ban logs
```

### Docker

```bash
sudo vpsg docker apply --yes
vpsg docker list
vpsg docker ports
sudo vpsg docker add-user deploy
```

把用户加入 docker 组前会明确警告：docker 组通常等价于 root 权限。

### 1Panel

```bash
vpsg panel status
vpsg panel plan
sudo vpsg panel install
vpsg panel info
```

VPS Guard **不会直接 `curl | bash`**。安装 1Panel 时先下载官方脚本到临时文件，检查不是 HTML/Cloudflare 错误页，显示 SHA-256 和脚本开头，再由管理员第二次确认执行。

### 网络 / VPS 工具

```bash
vpsg network summary
vpsg network speed 25
vpsg network route 1.1.1.1
vpsg network media
vpsg network bench
```

包含公网 IPv4/IPv6、DNS、轻量下载测速、mtr/traceroute、Netflix/YouTube/Disney+/Prime Video 可达性快速检查和 VPS 基础信息。

> `network media` 是“可达性快速检查”，不是完整的地区解锁判定器。

### 系统更新风险检查

```bash
vpsg system plan
sudo vpsg system apply
```

升级前会提示 Kernel / OpenSSH / Docker 相关更新和剩余磁盘空间；升级后再次检查 SSH 配置和 Docker 服务。

## VPS Guard Watch

让 VPS Guard 从“想起来才运行”变成“每天自动看一下”：

```bash
sudo vpsg watch enable
vpsg watch status
sudo vpsg watch run
vpsg watch latest
```

每天检查 Exposure + Drift，并把报告只保存在本机。当前版本**不会自动上传任何数据**。

## 异常现场采集

怀疑服务器有异常时先保存现场，而不是上来就杀进程：

```bash
sudo vpsg incident collect
```

会生成 root-only 压缩包，包含进程、socket、登录、SSH/Fail2Ban 日志、systemd、网络、Docker 等只读信息和 SHA-256 清单；不会复制 SSH 私钥或 `authorized_keys` 内容。

## 其他模块

- BBR
- Swap
- 系统状态 / doctor
- 日志、备份与回滚
- GitHub Actions CI
- Bash regression tests
- ShellCheck blocking/advisory 分级

## 安装

从 Release 下载源码并解压：

```bash
cd vps-guard
sudo bash install.sh
vpsg --version
vpsg doctor
```

使用 `bash install.sh` 是有意设计：即使 GitHub 网页上传或 ZIP 下载丢失 Unix executable bit，也不影响安装。安装后 `vpsg` 会通过 `/usr/local/bin/vpsg` 使用。

## 当前边界

VPS Guard 仍处于早期阶段。它不能替代：

- 云厂商安全组；
- Provider Console / Rescue Mode；
- 快照和异地备份；
- 专业 IDS/EDR；
- 对所有 nftables/iptables 自定义规则的完整证明；
- 完整的流媒体地区解锁测试。

高风险远程配置仍建议拥有 Provider Console 作为最后兜底。

## 文档

- [架构](docs/architecture.md)
- [安全模型](docs/security-model.md)
- [功能矩阵](docs/feature-matrix.md)
- [Roadmap](docs/roadmap.md)
- [贡献指南](CONTRIBUTING.md)
- [安全漏洞报告](SECURITY.md)

## License

MIT
