# shellcheck shell=bash
# OpenList 插件探针。sso=oidc（SSO 兼容模式，登录链结尾是 /@login?token=…），清单没有 mcp。
# 只用套件保证的变量（SMOKE_STATE/SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER）和助手（web_get/dweb）。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 SSO 登录链（网关 → 身份提供方 → /api/auth/sso_get_token →
#       /@login?token=…），拿应用令牌调 /api/me，断言认出的是管理员且 sso_id 是主人用户名。
# 数据：data_write 走 SSO 链拿管理员令牌，建一个带随机标记的用户，标记覆盖写进 $SMOKE_STATE；
#       data_check 读回标记重新走链，在用户列表里找。重装保数据后管理员和标记用户都还在。

export SSO=oidc
export MCP=0

web_assert() { grep -qi 'content="OpenList"'; }

# 数据标记的位置：SMOKE_STATE 是标记文件（e2e）；dev.sh probes 里它是状态目录，标记放目录内。
marker_file() {
  if [ -d "$SMOKE_STATE" ]; then printf '%s' "$SMOKE_STATE/data-marker"; else printf '%s' "$SMOKE_STATE"; fi
}

_ol_url() { # web_url 是 SSO 入口（带路径和查询），拼 API 前取 origin
  local u="${SMOKE_WEB_URL%%\?*}" rest="${SMOKE_WEB_URL#*://}"
  printf '%s://%s' "${u%%://*}" "${rest%%/*}"
}

ol_api() { # <路径> [curl 参数…]：带会话走网关调 OpenList API；HTTP 非 2xx 时打印响应体再失败
  local path="$1" out code
  shift
  out="$(curl -sS --noproxy '*' --max-time 120 -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" \
    -w '\n%{http_code}' "$@" "$(_ol_url)$path")" || { echo "请求失败：$out" >&2; return 1; }
  code="${out##*$'\n'}"
  [[ "$code" == 2* ]] || { echo "HTTP $code：$(head -c 300 <<<"${out%$'\n'*}")" >&2; return 1; }
  printf '%s' "${out%$'\n'*}"
}

# 走完 SSO 登录链，输出应用令牌；任何一步拿不到都返回非 0 并把现场打到标准错误。
sso_token() {
  local out code final token loc
  loc="$(curl -sS --noproxy '*' -o /dev/null -w '%{redirect_url}' \
    "$(_ol_url)/api/auth/sso?method=sso_get_token")"
  echo "SSO 首跳：$loc" >&2
  out="$(curl -sS --noproxy '*' -L --max-redirs 20 --max-time 120 \
    -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" -o /dev/null -w '%{http_code} %{url_effective}' \
    "$(_ol_url)/api/auth/sso?method=sso_get_token")" ||
    { echo "SSO 登录链请求失败" >&2; return 1; }
  code="${out%% *}"; final="${out#* }"
  [[ "$code" == 200 ]] || { echo "SSO 登录链返回 HTTP $code（OpenList 或身份提供方 5xx 时先看插件容器日志），停在：$final" >&2; return 1; }
  token="$(python3 -c 'import sys, urllib.parse as u
q = u.parse_qs(u.urlsplit(sys.argv[1]).query)
print(q.get("token", [""])[0])' "$final")"
  if [ -z "$token" ]; then
    echo "SSO 登录链结尾没有 token，停在：$final" >&2
    return 1
  fi
  printf '%s' "$token"
}

identity_check() {
  local token me
  token="$(sso_token)" || return 1
  me="$(ol_api '/api/me' -H "Authorization: $token")" || return 1
  python3 - "$me" "$SMOKE_OWNER" >&2 <<'PY' || { echo "应用认出的不是用户管理员：$me" >&2; return 1; }
import json, sys
me = json.loads(sys.argv[1])
assert me.get("code") == 200, me
data = me.get("data") or {}
# owner 的 SSO 身份绑在内置 admin 账号上：认出的用户必须是管理员（role=2），
# 且 sso_id 是 owner 的用户名（证明这条登录链就是 owner 的身份，不是别的账号）。
assert data.get("role") == 2, f"role={data.get('role')!r} 不是管理员"
assert data.get("sso_id") == sys.argv[2], f"sso_id={data.get('sso_id')!r} 不是 {sys.argv[2]!r}（绑定没生效）"
PY
}

# 数据：用户库存 在 OpenList 自己的数据目录里，升级、重装都保留。标记是确定性用户名
# （wonton-smoke-<实例>），不依赖 SMOKE_STATE 的形态；data_write 先删同名旧标记再建（重跑幂等），
# data_check 重装后在用户列表里找它。
ol_marker() { printf 'wonton-smoke-%s' "${SMOKE_INSTANCE:-owner}"; }

data_write() {
  local token marker resp id
  token="$(sso_token)" || return 1
  marker="$(ol_marker)"
  resp="$(ol_api '/api/admin/user/list?page=1&per_page=100' -H "Authorization: $token")" || return 1
  id="$(jq -r --arg m "$marker" '.data.content[]? | select(.username == $m) | .id' <<<"$resp" | head -1)"
  if [ -n "$id" ]; then
    ol_api '/api/admin/user/delete' -X POST -H "Authorization: $token" -H 'Content-Type: application/json' \
      -d "{\"id\":$id}" >/dev/null || { echo "删旧标记用户失败" >&2; return 1; }
  fi
  marker_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  resp="$(ol_api '/api/admin/user/create' -X POST -H "Authorization: $token" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$marker\",\"password\":\"$marker_password\",\"base_path\":\"/\",\"role\":0,\"permission\":0,\"disabled\":false}")" ||
    { echo "建标记用户失败" >&2; return 1; }
  echo "$resp" | grep -q '"code":200' || { echo "建标记用户被拒：$resp" >&2; return 1; }
}

data_check() {
  local token marker resp
  token="$(sso_token)" || return 1
  marker="$(ol_marker)"
  resp="$(ol_api '/api/admin/user/list?page=1&per_page=100' -H "Authorization: $token")" || return 1
  echo "$resp" | grep -q "\"username\":\"$marker\"" ||
    { echo "用户列表里没有标记用户 $marker：$(echo "$resp" | head -c 300)" >&2; return 1; }
}
