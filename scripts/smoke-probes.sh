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

# 走完 SSO 登录链，输出应用令牌；任何一步拿不到都返回非 0 并把现场打到标准错误。
sso_token() {
  local final token
  final="$(web_get '/api/auth/sso?method=sso_get_token' -L --max-time 120 -o /dev/null -w '%{url_effective}')" ||
    { echo "SSO 登录链请求失败" >&2; return 1; }
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
  me="$(web_get '/api/me' --max-time 60 -H "Authorization: $token")" ||
    { echo "GET /api/me 失败：$me" >&2; return 1; }
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

data_write() {
  local token marker resp password
  token="$(sso_token)" || return 1
  marker="$(python3 -c 'import secrets; print("smoke-" + secrets.token_hex(6))')"
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  resp="$(web_get '/api/admin/user/create' --max-time 60 \
    -X POST -H "Authorization: $token" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$marker\",\"password\":\"$password\",\"base_path\":\"/\",\"role\":0,\"permission\":0,\"disabled\":false}")" ||
    { echo "建标记用户失败：$resp" >&2; return 1; }
  echo "$resp" | grep -q '"code":200' || { echo "建标记用户被拒：$resp" >&2; return 1; }
  printf '%s\n' "$marker" >"$(marker_file)"
}

data_check() {
  local token marker resp
  token="$(sso_token)" || return 1
  marker="$(tail -1 "$(marker_file)" 2>/dev/null)"
  [ -n "$marker" ] || { echo "没有 data_write 写下的标记（$(marker_file)）" >&2; return 1; }
  resp="$(web_get '/api/admin/user/list?page=1&per_page=100' --max-time 60 -H "Authorization: $token")" ||
    { echo "列用户失败：$resp" >&2; return 1; }
  echo "$resp" | grep -q "\"username\":\"$marker\"" ||
    { echo "用户列表里没有标记用户 $marker：$(echo "$resp" | head -c 300)" >&2; return 1; }
}
