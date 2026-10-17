# 通过 EasyTier 组网访问 paseo

不想把 paseo 暴露在公网，又希望手机、笔记本等设备随时访问？可以用
[EasyTier](https://github.com/EasyTier/EasyTier) 在这些设备之间组一个虚拟局域网（mesh）。
设备加入同一个网络后，直接访问 **VPS 节点的虚拟 IP** 就能打开容器里的 paseo，
而且优先走 P2P 直连，延迟通常比 paseo 官方中继低。

本节针对 **Docker（VPS）** 模式。

## 核心结论：agent-devbox 不用改

EasyTier 跑在宿主上（`network_mode: host`），容器里的 paseo 保持官方默认的
`6767:6767`（即发布在 `0.0.0.0`）即可。

原因：`0.0.0.0` 已经覆盖了 EasyTier 的虚拟网卡，而 Docker 的端口发布是**按目的地址**
转发的，所以对端访问"节点虚拟 IP 的 6767"会被直接转发进容器 —— **mesh 访问默认就是通的**。

## 前提：VPS 的 EasyTier 必须是这个网络的“成员”

EasyTier 节点有两种角色：

| 角色 | 有虚拟 IP（如 `10.126.126.x`）吗 | 别人能访问它上面的服务吗 |
|---|---|---|
| 你的网络**成员**（配了 `--network-name` + `--network-secret`） | 有 | 能 |
| 纯中继 / 公共服务器（没有网络名） | 没有 | 不能 |

要让手机访问到这台 VPS，**VPS 的 EasyTier 必须加入你的网络**。

先确认它是否已经是成员（在 VPS 上执行）：

```bash
easytier-cli node                 # 看本节点虚拟 IPv4
ip -4 addr | grep 10.126.126      # 或直接在宿主网卡里找
```

- 能看到 `10.126.126.x` → 已经是成员，**EasyTier 不用动**。
- 看不到 → 它没入网，启动时加上 `--network-name` / `--network-secret`。

> 一个 EasyTier 节点可以**既是某网络的成员、又给其他网络中继**（默认行为），
> 所以让 VPS 入网不会影响它继续当服务器。

## 步骤

### 1. VPS 上跑 EasyTier（host 网络），加入你的网络

建议给这个节点**固定**一个虚拟 IP，这样手机每次都用同一个地址：

```bash
easytier-core \
  --network-name  my-mesh \
  --network-secret 'CHANGE_ME_STRONG' \
  -i 10.126.126.1 \
  -p tcp://<共享节点或本网络其他节点>:11010
```

- `-i 10.126.126.1`：固定虚拟 IP。不写则自动分配（默认网段 `10.126.126.0/24`），地址可能变化。
- `-p`：指定一个可达的共享节点 / 对端做入口，用来发现其他节点。
- `--network-name` + `--network-secret` 要和手机、Windows 保持一致。

Docker 部署参考（官方推荐 host 网络）：

```yaml
services:
  easytier:
    image: easytier/easytier:latest
    restart: unless-stopped
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    devices: ["/dev/net/tun:/dev/net/tun"]
    volumes: ["/etc/machine-id:/etc/machine-id:ro"]
    command: >
      --network-name my-mesh
      --network-secret CHANGE_ME_STRONG
      -i 10.126.126.1
      -p tcp://<共享节点>:11010
```

> 为了 P2P 直连更顺，记得在 VPS 的云安全组 / 防火墙放行 EasyTier 的监听端口
> —— 默认是 `11010/tcp`、`11010/udp`、`11011`（wg / ws）、`11012`（wss）。

### 2. 照常启动 agent-devbox

```bash
cp .env.example .env      # 设置 PASEO_PASSWORD（必填）
docker compose up -d
```

**不用加任何端口 / 网络配置**，保持 `6767:6767` 即可。

### 3. 手机加入同一个网络

在手机上安装 EasyTier 客户端，填**同样的** `--network-name` 和 `--network-secret`，
加入后手机自己也会得到一个 `10.126.126.x` 地址。

### 4. 手机访问

浏览器打开：

```text
http://10.126.126.1:6767
```

`10.126.126.1` 换成第 1 步给 VPS 固定的虚拟 IP，然后输入 `PASEO_PASSWORD` 登录。

## 原理

```text
手机浏览器 → http://10.126.126.1:6767
  ↓ 手机 EasyTier 把包送进 mesh（优先 P2P 直连，直连不通才走中继）
  ↓ 到达 VPS 节点（虚拟 IP 10.126.126.1）
  ↓ Docker 端口发布按目的地址转发：10.126.126.1:6767 → 容器:6767
  ↓ 容器里的 paseo，输入 PASEO_PASSWORD
```

容器**自身不参与 mesh**，它一直在 Docker 网络里；mesh 的“落点”是 VPS 这个节点，
Docker 只是把落在 6767 上的流量转进容器。

## 可选：不让公网也能访问 6767

`6767:6767` 会同时发布到**所有网卡**（公网、localhost、以及 EasyTier 的虚拟网卡）。
如果只想让 mesh 访问、不想公网也开着，二选一（都不需要知道 EasyTier 的 IP）：

- **最简单**：在 VPS 的**云安全组**里**不放行 6767**。这不影响 mesh —— mesh 的包是在
  EasyTier 解封装之后从虚拟网卡进来的，根本不走公网网卡。
- **宿主防火墙**（写进 `DOCKER-USER` 链，规则在这里才不会被 Docker 覆盖）：

  ```bash
  iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A DOCKER-USER -p tcp --dport 6767 -s 10.126.126.0/24 -j ACCEPT
  iptables -A DOCKER-USER -p tcp --dport 6767 -j DROP
  # 持久化（重启后仍然生效）：
  apt-get install -y iptables-persistent && netfilter-persistent save
  ```

> `PASEO_PASSWORD` 始终是必需的第一道门；上面两步只是额外收紧来源。

## 说明

- **用 IP 访问无需任何额外配置**。只有改用域名（如 `paseo.mesh`）访问时，才需要在
  `.env` 里设置 `PASEO_HOSTNAMES`，否则会被 Host 校验挡下（返回 403）。
- **paseo 本身没有源 IP 白名单**（没有“只允许某网段”的开关），所以“限制来源”只能靠
  **绑网卡**或**防火墙**实现，见上一节。
- 如果 VPS 的 EasyTier 只是**纯中继**（没入网），它没有虚拟 IP，手机在网里也找不到它；
  必须让它加入你的网络（第 1 步）。
- **进阶**：若要让容器本身成为 mesh 的一等公民（有独立虚拟 IP、双向原生可达），可以用
  “共享 network namespace” 的 sidecar（`network_mode: "service:easytier"`）。但 EasyTier
  官方只文档化了 host 模式，且桥接会多一层容器 NAT、可能削弱 P2P，一般**不需要** —— 上面的
  host 方案已能满足“手机访问 paseo”。
