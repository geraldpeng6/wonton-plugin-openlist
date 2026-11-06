# shellcheck shell=bash
# OpenList 插件探针。两套 harness 都能跑：dev.sh probes 提供 SMOKE_*，e2e/smoke.sh 提供 E2E_*。
# sso=oidc（SSO 兼容模式，登录链结尾是 /@login?token=…），清单没有 mcp。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 SSO 登录链（网关 → 身份提供方 → /api/auth/sso_get_token →
#       /@login?token=…），拿应用令牌调 /api/me，断言认出的是 owner 且角色是管理员。
# 数据：data_write 走 SSO 链拿管理员令牌，建一个带随机标记的用户，标记写进 jar 旁边的
#       标记文件（e2e 的 SMOKE_STATE 是文件，dev.sh probes 里是目录，旁边最稳）；
#       data_check 重新走链拿令牌，在用户列表里找标记。重装保数据后管理员和标记用户都还在。

export SSO=oidc
export MCP=0

# 变量在函数运行时才解析：e2e 在 source 之后才定义 E2E_JAR/E2E_WEB_URL（且 E2E_JAR 没 export，
# 但探针函数 source 进了 harness 的同一 shell，运行时能读到）；dev.sh probes 用 SMOKE_*。
jar() { printf '%s' "${SMOKE_JAR:-${E2E_JAR:-}}"; }
web_url() { printf '%s' "${SMOKE_WEB_URL:-${E2E_WEB_URL:-}}"; }
owner() { printf '%s' "${SMOKE_OWNER:-${E2E_OWNER:-owner}}"; }
marker_file() { printf '%s.data-marker' "$(jar)"; }

web_assert() { grep -qi 'content="OpenList"'; }

# 走完 SSO 登录链，输出应用令牌；任何一步拿不到都返回非 0 并把现场打到标准错误。
sso_token() {
  local final token
  final="$(curl -sS --noproxy '*' --max-time 120 -o /dev/null -L -b "$(jar)" -c "$(jar)" \
    -H 'Accept: text/html' -w '%{url_effective}' \
    "$(web_url)/api/auth/sso?method=sso_get_token")" ||
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
  me="$(curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "$(jar)" \
    -H "Authorization: $token" "$(web_url)/api/me")" ||
    { echo "GET /api/me 失败" >&2; return 1; }
  python3 - "$me" "$(owner)" >&2 <<'PY' || { echo "应用认出的不是用户管理员：$me" >&2; return 1; }
import json, sys
me = json.loads(sys.argv[1])
assert me.get("code") == 200, me
data = me.get("data") or {}
assert data.get("username") == sys.argv[2], f"username={data.get('username')!r} 不是 {sys.argv[2]!r}"
assert data.get("role") == 2, f"role={data.get('role')!r} 不是管理员"
PY
}

data_write() {
  local token marker resp password
  token="$(sso_token)" || return 1
  marker="$(python3 -c 'import secrets; print("smoke-" + secrets.token_hex(6))')"
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  resp="$(curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "$(jar)" \
    -H "Authorization: $token" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$marker\",\"password\":\"$password\",\"base_path\":\"/\",\"role\":0,\"permission\":0,\"disabled\":false}" \
    "$(web_url)/api/admin/user/create")" ||
    { echo "建标记用户失败：$resp" >&2; return 1; }
  echo "$resp" | grep -q '"code":200' || { echo "建标记用户被拒：$resp" >&2; return 1; }
  printf '%s\n' "$marker" >>"$(marker_file)"
}

data_check() {
  local token marker resp
  token="$(sso_token)" || return 1
  marker="$(tail -1 "$(marker_file)" 2>/dev/null)"
  [ -n "$marker" ] || { echo "没有 data_write 写下的标记（$(marker_file)）" >&2; return 1; }
  resp="$(curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "$(jar)" \
    -H "Authorization: $token" "$(web_url)/api/admin/user/list?page=1&per_page=100")" ||
    { echo "列用户失败：$resp" >&2; return 1; }
  echo "$resp" | grep -q "\"username\":\"$marker\"" ||
    { echo "用户列表里没有标记用户 $marker：$(echo "$resp" | head -c 300)" >&2; return 1; }
}
