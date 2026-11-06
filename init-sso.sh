# shellcheck shell=sh
# OpenList 的 SSO 配置存在数据库设置表里（没有 config.json 或环境变量入口），
# 只能经应用自己的管理 API 写入。本脚本在每次创建容器时重跑，全部操作幂等：
# 已是目标值时写回去的结果不变；owner 的绑定每装一次核对一次。
# 失败即停：任何一步拿不到预期响应就以非 0 退出，安装会带着日志回滚。
set -eu

API="http://openlist:5244/api"

say() { echo "[init-sso] $*"; }
die() { echo "[init-sso] $*" >&2; exit 1; }
need() { [ -n "$2" ] || die "环境变量 $1 没有值"; }

need WONTON_OWNER_NAME "$WONTON_OWNER_NAME"
need WONTON_SECRET_ADMIN_PASSWORD "$WONTON_SECRET_ADMIN_PASSWORD"
need WONTON_OIDC_ISSUER "$WONTON_OIDC_ISSUER"
need WONTON_OIDC_CLIENT_ID "$WONTON_OIDC_CLIENT_ID"
need WONTON_OIDC_CLIENT_SECRET "$WONTON_OIDC_CLIENT_SECRET"

# curl 帮手：带 JSON 头 POST/GET，非 2xx 直接失败。服务间直连，走插件网络里的服务名。
req() { # <method> <url> [body] [额外 curl 参数…]
  method=$1
  url=$2
  shift 2
  body=""
  if [ $# -gt 0 ]; then
    case $1 in
      -*) ;;
      *) body=$1; shift ;;
    esac
  fi
  if [ -n "$body" ]; then
    curl -sS --noproxy '*' -X "$method" -H 'Content-Type: application/json' --data "$body" "$@" "$url"
  else
    curl -sS --noproxy '*' -X "$method" "$@" "$url"
  fi
}

authed() { # <method> <path> [body]：带管理员令牌调管理接口
  if [ $# -ge 3 ]; then
    req "$1" "$API$2" "$3" -H "Authorization: $TOKEN"
  else
    req "$1" "$API$2" -H "Authorization: $TOKEN"
  fi
}

# ---- 1. 管理员登录（密码来自注入的密钥，OPENLIST_ADMIN_PASSWORD 首启已建号） ----
login="$(req POST "$API/auth/login" "{\"username\":\"admin\",\"password\":\"$WONTON_SECRET_ADMIN_PASSWORD\"}")"
echo "$login" | grep -q '"code":200' || die "管理员登录失败：$login"
TOKEN="$(echo "$login" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || die "登录响应里没有令牌：$login"
say "管理员登录成功"

# ---- 2. 写 SSO 设置（group=7 的全部受管项；type/flag 与上游默认一致） ----
SETTINGS="[
 {\"key\":\"sso_login_enabled\",\"value\":\"true\",\"type\":\"bool\",\"group\":7,\"flag\":0,\"options\":\"\"},
 {\"key\":\"sso_login_platform\",\"value\":\"OIDC\",\"type\":\"select\",\"group\":7,\"flag\":0,\"options\":\"Casdoor,Github,Microsoft,Google,Dingtalk,OIDC\"},
 {\"key\":\"sso_client_id\",\"value\":\"$WONTON_OIDC_CLIENT_ID\",\"type\":\"string\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_client_secret\",\"value\":\"$WONTON_OIDC_CLIENT_SECRET\",\"type\":\"string\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_oidc_username_key\",\"value\":\"preferred_username\",\"type\":\"string\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_endpoint_name\",\"value\":\"$WONTON_OIDC_ISSUER\",\"type\":\"string\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_auto_register\",\"value\":\"true\",\"type\":\"bool\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_default_dir\",\"value\":\"/\",\"type\":\"string\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_default_permission\",\"value\":\"65535\",\"type\":\"number\",\"group\":7,\"flag\":1,\"options\":\"\"},
 {\"key\":\"sso_compatibility_mode\",\"value\":\"true\",\"type\":\"bool\",\"group\":7,\"flag\":0,\"options\":\"\"}
]"
saved="$(authed POST /admin/setting/save "$SETTINGS")"
echo "$saved" | grep -q '"code":200' || die "SSO 设置写入失败：$saved"
say "SSO 设置已写入（平台 OIDC、兼容模式、自动注册）"

# ---- 3. 把 owner 的 OIDC 身份绑到内置管理员账号（id=1，即首启第一个建号的用户） ----
user_json="$(authed GET "/admin/user/get?id=1")"
echo "$user_json" | grep -q '"code":200' || die "读取管理员用户失败：$user_json"
echo "$user_json" | grep -q '"username":"admin"' || die "id=1 不是 admin，绑定中止：$user_json"
if echo "$user_json" | grep -q "\"sso_id\":\"$WONTON_OWNER_NAME\""; then
  say "管理员已绑定 owner 身份（sso_id=$WONTON_OWNER_NAME），跳过"
else
  bound="$(echo "$user_json" | sed 's/"sso_id":"[^"]*"/"sso_id":"'"$WONTON_OWNER_NAME"'"/')"
  updated="$(authed POST /admin/user/update "$bound")"
  echo "$updated" | grep -q '"code":200' || die "绑定 owner 身份失败：$updated"
  say "已把 owner（$WONTON_OWNER_NAME）绑定为管理员账号"
fi

say "完成"
