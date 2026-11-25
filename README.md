# Zabbix Ubuntu 26.04 QuickInstall

**Zabbix 8.0 LTS（当前最新长期支持版）在 Ubuntu 26.04 (Resolute) 上的一键部署脚本。**

遵循 [Zabbix 官方安装文档](https://www.zabbix.com/download) 的标准流程，支持：

- 🌐 **外网在线安装**：直接从 `repo.zabbix.com` 官方源安装
- 🏢 **内网离线安装**：先在有外网的机器上制作离线包，再拷贝到内网服务器安装
- 🔒 生产环境加固项：随机强数据库密码、日志留痕、服务自检、防火墙放行

---

## 功能特性

| 特性 | 说明 |
|---|---|
| 双模式安装 | 在线 / 离线（`--offline`）同一脚本 |
| 组件 | Zabbix Server + Web 前端 + Agent2（可选经典 Agent） |
| 数据库 | MySQL 8（本机自动安装配置，或 `--db-host` 指定远程库） |
| Web 服务器 | Apache（默认）或 Nginx（`--webserver nginx`） |
| 密码管理 | 未指定时自动生成 24 位强密码，保存至 `/root/.zabbix-db-password` |
| 非交互部署 | 支持 `--config` 配置文件 + `--non-interactive`，适合批量/CI |
| 安全日志 | 全程输出记录到 `/var/log/zabbix-install.log`（600 权限） |
| 自检 | 安装后自动验证服务状态与启动日志，失败即报错 |
| 可重入 | 失败后修复问题可直接重跑 |

---

## 快速开始（外网服务器）

```bash
git clone https://github.com/<your-username>/zabbix-ubuntu26-quickinstall.git
cd zabbix-ubuntu26-quickinstall
sudo bash install-zabbix.sh
```

安装完成后：

- 访问 `http://<服务器IP>/zabbix`
- 默认账号 `Admin / zabbix` —— **登录后立即修改密码！**
- 数据库凭据在 `/root/.zabbix-db-password`

### 常用参数

```bash
# 指定数据库密码与时区
sudo bash install-zabbix.sh --db-password 'S3cret!' --timezone Asia/Shanghai

# Nginx 前端 + 经典 Agent
sudo bash install-zabbix.sh --webserver nginx --agent

# 使用远程 MySQL（需提供 root 密码）
sudo bash install-zabbix.sh --db-host 10.0.0.8 --db-root-password 'RootPass'

# 不动防火墙
sudo bash install-zabbix.sh --no-firewall
```

<details>
<summary>全部参数</summary>

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--version <ver>` | `8.0` | Zabbix 主版本 |
| `--db-password <pass>` | 自动生成 | zabbix 数据库用户密码 |
| `--db-host <host>` | `localhost` | MySQL 地址，localhost 表示本机 |
| `--db-root-password <p>` | 空 | 远程数据库时必填 |
| `--webserver <ws>` | `apache` | `apache` 或 `nginx` |
| `--agent2` | 默认 | 安装 zabbix-agent2 |
| `--agent` | — | 改装经典 zabbix-agent |
| `--timezone <tz>` | `Asia/Shanghai` | 系统/PHP 时区 |
| `--no-firewall` | — | 跳过防火墙配置 |
| `--offline <dir\|tar.gz>` | — | 离线安装模式 |
| `--config <file>` | — | 从配置文件读取参数 |
| `--non-interactive` | — | 非交互模式（全部用参数/默认值） |

</details>

---

## 内网离线部署

### 第 1 步：在有外网的 Ubuntu 26.04 机器上制作离线包

```bash
sudo bash make-offline-package.sh
# 可选：sudo bash make-offline-package.sh --webserver nginx --agent
```

生成 `zabbix-offline-8.0-ubuntu26.04-amd64-<日期>.tar.gz`（含全部 deb 依赖 + SHA256 校验）。

> 注意：制作机的 **系统版本（26.04）和架构（amd64/arm64）必须与目标内网服务器一致**。

### 第 2 步：拷贝到内网服务器并安装

```bash
# 用 U 盘 / 内网 scp 传输后：
sha256sum -c zabbix-offline-8.0-ubuntu26.04-amd64-xxx.tar.gz.sha256   # 校验
sudo bash install-zabbix.sh --offline zabbix-offline-8.0-ubuntu26.04-amd64-xxx.tar.gz
```

---

## 非交互 / 批量部署

```bash
cp config.example.conf my.conf && vi my.conf
sudo bash install-zabbix.sh --config my.conf --non-interactive
```

---

## 生产环境加固清单

安装只是第一步，上线前建议完成：

1. **改默认口令**：前端 `Admin` 密码、数据库密码都用强密码
2. **HTTPS**：`certbot --apache`（外网）或企业证书 + 强制 443 跳转
3. **端口收敛**：公网只放行 80/443；10051 仅对被监控网段开放；10050 仅内网
4. **MySQL 调优**：`innodb_buffer_pool_size` 设为物理内存 50–70%
5. **定时备份**：每日 `mysqldump zabbix` + `/etc/zabbix/` 配置目录
6. **规模扩大时**：加装 TimescaleDB、部署 Zabbix Proxy 分担采集

## 系统要求

- Ubuntu 26.04 (Resolute)，amd64 / arm64
- 建议 ≥ 4 vCPU / 8 GB RAM / SSD
- 外网模式需要能访问 `repo.zabbix.com` 和 Ubuntu 官方源

## 常见问题

<details>
<summary>安装后前端打不开？</summary>

- 检查防火墙/云安全组是否放行 80（或 443）
- `systemctl status apache2 nginx php*-fpm` 确认服务在跑
- Apache 模式需 `a2enmod proxy proxy_fcgi`（脚本已自动执行）
</details>

<details>
<summary>zabbix-server 起不来？</summary>

- `tail -50 /var/log/zabbix/zabbix_server.log`
- 多为数据库密码错误或 schema 未导入完成，修正后重启即可
- 脚本可安全重跑，已导入的数据不会重复导入（`CREATE ... IF NOT EXISTS`）
</details>

<details>
<summary>想装 7.0 LTS / 7.4？</summary>

```bash
sudo bash install-zabbix.sh --version 7.0
```
</details>

## License

[MIT](LICENSE)

## 致谢

- [Zabbix LLC](https://www.zabbix.com/) — 官方安装文档与软件源
- 社区脚本参考：[X-Mars/Quick-Installation-ZABBIX](https://github.com/X-Mars/Quick-Installation-ZABBIX)、[databloat/zabbix-full-deployer](https://github.com/databloat/zabbix-full-deployer)
