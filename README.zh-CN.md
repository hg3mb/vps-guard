# VPS Guard

[![CI](https://github.com/hg3mb/vps-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/hg3mb/vps-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/hg3mb/vps-guard)](https://github.com/hg3mb/vps-guard/releases/latest)
[![License](https://img.shields.io/github/license/hg3mb/vps-guard)](LICENSE)


**安全优先、好用易懂的 Debian / Ubuntu VPS 加固与日常运维工具。**

VPS Guard 的目标不是把几十个“一键脚本”塞进菜单，而是在常用功能够用的基础上，把普通 VPS 用户最容易踩坑的几件事做好：

1. **SSH / 防火墙改错导致失联，能不能自己恢复？**
2. **服务器实际上向外暴露了什么，包括 Docker 端口？**
3. **服务器从上次确认可信以后，到底发生了什么变化？**
4. **“没发现问题”和“根本没检查到”能不能明确区分？**

当前版本：**v0.4.0** · [项目仓库](https://github.com/hg3mb/vps-guard) · [最新 Release](https://github.com/hg3mb/vps-guard/releases/latest)

> 项目仍处于早期阶段。修改远程访问控制时，仍建议保留云厂商 Console / VNC / Rescue Mode 作为最后兜底。

## 三个核心能力

### Safe Change Engine 3.0 — 改错了也有后悔药

SSH 和关键 UFW 修改不是“执行完就算了”，而是一个安全事务：

```text
修改前检查
  ↓
保存恢复点
  ↓
启动独立 systemd 自动回滚
  ↓
应用修改
  ↓
验证实际生效状态
  ↓
重新建立 SSH 登录 / Console 明确确认
  ↓
commit 才永久保留

超时没 commit → 自动恢复
```

```bash
sudo vpsg ssh apply --disable-password --yes
vpsg safe status
sudo vpsg commit
vpsg safe history
```

v0.4.0 重点加强：

- 同一时间只允许一个访问关键事务；
- root-only 状态、恢复脚本和事件历史；
- 自动回滚不依赖发起修改的 SSH 窗口；
- SSH 同时验证语法和 **实际 effective config**；
- 同一个 SSH 登录会话不能直接把危险修改 commit；
- 支持手工 rollback、延长倒计时、历史查看；
- `apply_failed / rolling_back / rollback_failed` 都不会被当成“已经安全结束”。

### Exposure Analyzer 3.0 — 看清真实暴露面

```bash
sudo vpsg exposure scan
vpsg exposure explain 6379
vpsg exposure profile set web
vpsg exposure json
```

它不是只跑一下 `ss`，而是统一分析：

- TCP / UDP listener；
- loopback / 私网 / CGNAT / 公网指定地址 / wildcard；
- Docker structured published ports；
- UFW 上下文；
- Docker 容器内部端口对应的服务类型；
- 当前服务器用途 Profile。

风险使用可解释的：

```text
CRITICAL / HIGH / MEDIUM / LOW / INFO
```

例如宿主机映射 `13306 -> mysql:3306`，不会因为宿主端口不是 3306 就漏掉数据库风险。

如果 Docker 已安装、但当前用户没有权限读取 Docker daemon，VPS Guard 会明确显示 **扫描不完整**，而不是错误告诉你“没有 Docker 暴露”。

### Baseline & Semantic Drift 3.0 — 告诉你后来发生了什么

服务器配置完成、确认可信后：

```bash
sudo vpsg baseline create
sudo vpsg baseline verify
```

以后检查：

```bash
sudo vpsg drift scan
vpsg drift history
```

报告更像：

```text
CRITICAL  + Docker API 新增公网发布
HIGH      + authorized_keys 发生变化
HIGH      + sudo 权限变化
MEDIUM    + 新增可登录用户
MEDIUM    + 某个安全采集器从完整变为不完整
INFO      - 原有监听端口消失
```

Baseline 不保存 SSH 私钥，也不复制 `authorized_keys` 内容，只保存需要的路径、数量和哈希等元数据。

完整性不只验证“已有文件内容有没有被改”，也验证**应该存在的文件集合有没有被偷偷增加/删除**。每个采集器还会记录 `ok / incomplete(...)`，避免把“扫描失败后的空结果”当成安全。

确认某次 Drift 的变化确实是自己操作后，可以把**那一次已经审核过的快照**接受为新基线：

```bash
sudo vpsg drift accept <report-id>
```

## 新手怎么用

安装后直接：

```bash
vpsg
```

或者：

```bash
vpsg setup guide
```

推荐流程：

```text
Doctor / Exposure
  ↓
选择服务器用途 Profile
  ↓
创建第二管理员 + SSH Key
  ↓
Fail2Ban + 自动安全更新
  ↓
Safe Change 配置 SSH / UFW
  ↓
建立 Baseline
  ↓
开启 Watch
```

项目**不会提供“回车后把整台 VPS 全部重写”的危险模式**。

## 日常实用功能

### 用户 / sudo / GitHub SSH Key

```bash
vpsg users list
sudo vpsg users bootstrap deploy octocat
sudo vpsg users add deploy --sudo
sudo vpsg ssh import-github octocat --user deploy
```

会区分密码字段状态、sudo、SSH Key 数量，不把 `passwd -l` 简单描述成“整个 SSH 账户已锁死”。

### UFW

```bash
vpsg firewall status
sudo vpsg firewall apply --yes
sudo vpsg firewall web
sudo vpsg firewall allow 8080 tcp
sudo vpsg firewall deny 3306 tcp
```

会保护检测到的当前 SSH 管理端口，并对关键 apply 使用 Safe Change。

### Fail2Ban

```bash
sudo vpsg fail2ban apply --yes
vpsg fail2ban banned
sudo vpsg fail2ban unban 203.0.113.10
vpsg fail2ban logs
```

只管理自己的 `jail.d` 片段，并对配置和服务生命周期做验证/回滚。

### Docker

```bash
sudo vpsg docker apply --yes
vpsg docker list
vpsg docker ports
sudo vpsg docker add-user deploy
```

Docker CE 安装会先做 APT 模拟和冲突包分析，不默认使用 convenience `curl | bash`。把用户加入 `docker` 组前会明确提醒：这通常接近 root 权限。

### 1Panel

```bash
vpsg panel status
vpsg panel plan
sudo vpsg panel install
```

官方安装脚本会先下载到临时文件，检查 HTTPS/明显错误页、显示 SHA-256 和预览，再二次确认执行。

### 系统更新

```bash
vpsg system plan
sudo vpsg system apply
sudo vpsg system auto-enable
```

使用 APT simulation 分析 Kernel、OpenSSH、Docker/containerd、held packages、磁盘和 reboot-required。自动安全更新默认**不自动重启 VPS**。

### 网络 / VPS 工具

```bash
vpsg network summary
vpsg network speed 25
vpsg network route 1.1.1.1
vpsg network media
vpsg network yabs
vpsg network region
```

基础网络功能由 VPS Guard 内置；YABS 和 RegionRestrictionCheck 属于明确的第三方集成边界，不把不同许可证的大段代码复制进本项目。

### Watch 2.0

```bash
sudo vpsg watch enable
vpsg watch status
sudo vpsg watch run
vpsg watch latest
```

每天本地运行 Exposure + Drift。相同风险不会每天重复通知；通知 hook 失败也不会错误记录成成功。默认不会把服务器数据上传出去。

### Incident Collector

```bash
sudo vpsg incident collect
```

收集进程名、socket、登录、SSH/Fail2Ban 日志、systemd、网络、Docker 等只读现场信息。

默认**不采集完整进程命令行**，因为 argv 很可能包含 Token / 密码。确实需要时才显式开启相应选项。压缩包 root-only，并带内部 `SHA256SUMS`。

## 安装 / 升级 / 程序回滚

### 从 Release 安装

从 [最新 GitHub Release](https://github.com/hg3mb/vps-guard/releases/latest) 下载压缩包；如果 Release 同时提供 `SHA256SUMS`，建议先校验，然后解压：

```bash
cd vps-guard-0.4.0
sudo bash install.sh
vpsg --version
vpsg doctor
```

### 从 Git 安装

```bash
git clone https://github.com/hg3mb/vps-guard.git
cd vps-guard
sudo bash install.sh
vpsg doctor
```

升级继续运行新版 `install.sh` 即可。

如果只想恢复 VPS Guard **程序版本**：

```bash
sudo bash install.sh --rollback
```

注意：程序版本 rollback 和 SSH/UFW Safe Change rollback 是两套独立机制，不会混在一起。

## 正式支持目标

CI 自动回归覆盖：

- Debian 12
- Debian 13
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

不同 VPS 厂商镜像、网络和预装组件仍可能产生差异，欢迎提供真实环境报告。

## 测试

当前回归套件：**114 项全部通过（本地 Debian 环境）**。

```bash
bash tests/run.sh
bash scripts/build-release.sh ./dist --self-test
```

CI 还会运行 Debian/Ubuntu matrix、ShellCheck 和 Release archive 自检。

## 安全原则

- 危险远程配置默认可回滚；
- 写入配置后验证实际状态，不只验证“文件写成功”；
- 扫描不完整就明确说不完整；
- Docker published ports 不会因为简单 UFW 状态就被判定安全；
- Baseline 不保存 SSH 私钥/authorized_keys 原文；
- 第三方脚本必须经过明确的 staging / 检查 / 确认边界；
- Watch / Incident 默认本地保存；
- 卸载时如果还有未解决 Safe Change，会拒绝删除恢复能力。

## 项目边界

VPS Guard 不能替代：云厂商安全组、Console/Rescue、快照/异地备份、专业 IDS/EDR，也不能仅凭主机状态证明某个端口一定能从互联网访问。

## 文档

- [架构](docs/architecture.md)
- [安全模型](docs/security-model.md)
- [功能矩阵](docs/feature-matrix.md)
- [Roadmap](docs/roadmap.md)
- [贡献指南](CONTRIBUTING.md)
- [漏洞报告](SECURITY.md)
- [English README](README.md)

## License

MIT。第三方工具继续遵循各自上游许可证，不并入 VPS Guard 的 MIT 源码。
