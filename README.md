# 云吞插件：OpenList

把 [OpenList](https://github.com/OpenListTeam/OpenList) 做成[云吞](https://github.com/geraldpeng6/wonton-docs)插件：经云吞网关单点登录打开，把各家网盘（阿里云盘、夸克、百度网盘等）聚合挂载到一个网页，浏览、在线播放、上传下载、离线下载都在一个界面。

## 和 Alist 的关系

OpenList 是 **Alist v3 的社区延续分支**。2025 年 6 月 Alist 项目易主引发社区争议后，原社区以 OpenList 的名义继续维护同一套代码（fork 自 Alist v3，上游 https://github.com/OpenListTeam/OpenList ，AGPL-3.0），Alist 原仓库的高风险改动不再进入这条线。本插件封装的是 OpenList，不是 Alist；从 Alist 迁移过来的用户可以直接用 OpenList 的导入功能，插件 README 不再重复。

## 怎么工作

- 上游官方镜像 `openlistteam/openlist`，按多架构清单摘要固定（amd64、arm64）。
- 登录走 `sso: oidc`：核心身份提供方登录后，直接落进 OpenList 文件页，不再看到第二个登录页。OpenList 的 SSO 配置存在应用数据库里，由一次性服务 `init-sso` 经应用自己的管理 API 写入（每次容器创建幂等重跑），并把 owner 的身份绑到内置管理员账号。
- 出网挂载网盘是 OpenList 的核心功能，因此申请 `network.egress`；`owner.identity` 用于把 owner 用户名写进管理员账号的 SSO 绑定。
- 数据（SQLite、配置、日志）放在插件数据目录，升级、重装保留。
- 健康检查打 `/api/public/settings`：存储加载完成后才放行的接口，检查的是真正可用。

## 图标与商标

`icon.svg` 用的是 OpenList 官方标志（来源、许可与商标说明见 [NOTICE](NOTICE)）。

## 开发

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)：

```bash
scripts/check.sh --official
scripts/dev.sh up && scripts/dev.sh install
scripts/dev.sh probes
```
