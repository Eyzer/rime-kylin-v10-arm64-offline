#!/usr/bin/env bash
# 中州韵（Rime）输入法的配置编辑器 —— Linux fcitx5 / fcitx4 / ibus
# 只读写 *_custom.yaml 与 default.custom.yaml，绝不改动发行版自带的 default.yaml
set -uo pipefail

RIME_DIR="${RIME_DIR:-}"
CUSTOM=""

info(){ printf '\033[1;36m%s\033[0m\n' "$*"; }
ok(){   printf '\033[0;32m%s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
err(){  printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
pause(){ printf '\n按回车继续...'; local _x=""; read -r _x; }

# ---------- 目录 ----------
detect_rime_dir(){
  local c
  for c in "${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime" \
           "$HOME/.config/fcitx/rime" \
           "$HOME/.config/ibus/rime" \
           "$HOME/.config/fcitx5/rime"; do
    [ -d "$c" ] && { RIME_DIR="$c"; return 0; }
  done
  return 1
}

# ---------- 文件层 ----------
backup_custom(){
  [ -f "$CUSTOM" ] || return 0
  local b="$CUSTOM.bak.$(date +%Y%m%d-%H%M%S)"
  [ -e "$b" ] || cp -p "$CUSTOM" "$b"
}

ensure_custom(){
  if [ ! -f "$CUSTOM" ]; then
    { printf '# 由 rime-config 维护\n'; printf 'patch:\n'; } > "$CUSTOM"
  elif ! grep -qE '^patch:[[:space:]]*$' "$CUSTOM"; then
    printf '\npatch:\n' >> "$CUSTOM"
  fi
}

patch_not_last(){
  awk '/^patch:[[:space:]]*$/ {p=NR} p && NR>p && /^[^[:space:]#]/ {print "1"; exit}' "$CUSTOM"
}

# 删掉 patch 下某个键（含其缩进续行），保证不重复
drop_key(){
  awk -v k="$1" '
    del {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^ */); if (RLENGTH > 2) next
      del = 0
    }
    !del && (index($0, "  " k ":") == 1 || index($0, "  \"" k "\":") == 1) { del = 1; next }
    !del { print }
  ' "$CUSTOM" > "$CUSTOM.tmp" && mv "$CUSTOM.tmp" "$CUSTOM"
}

set_patch_scalar(){
  ensure_custom
  if [ -n "$(patch_not_last)" ]; then
    warn "patch: 不在文件末尾，写入位置会出错，已中止。请先手动整理该文件。"
    return 1
  fi
  backup_custom
  drop_key "$1"
  printf '  %s: %s\n' "$1" "$2" >> "$CUSTOM"
}

# shortcut: 取所有 "- schema:" 行，若某方案文件在 schema_list 之外也用了该写法会误抓
read_schema_list(){
  [ -f "$1" ] || return 0
  awk '/^[[:space:]]*-[[:space:]]*schema:/ {sub(/^[[:space:]]*-[[:space:]]*schema:[[:space:]]*/,""); print}' "$1"
}

write_schema_list(){
  ensure_custom
  if [ -n "$(patch_not_last)" ]; then
    warn "patch: 不在文件末尾，写入位置会出错，已中止。"
    return 1
  fi
  backup_custom
  drop_key schema_list
  { printf '  schema_list:\n'; local s; for s in $1; do printf '    - schema: %s\n' "$s"; done; } >> "$CUSTOM"
}

# ---------- 功能 ----------
show_summary(){
  info "配置目录：$RIME_DIR"
  printf '自定义配置：%s\n\n' "$CUSTOM"
  local n
  n=$(awk '/^  menu\/page_size:/ {print $NF; exit}' "$CUSTOM" 2>/dev/null)
  printf '候选词个数：%s\n' "${n:-未设置（默认 5）}"
  printf '已启用的输入方案：\n'
  local -A seen=()
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    [ -n "${seen[$s]:-}" ] && continue
    seen[$s]=1
    printf '  - %s\n' "$s"
  done < <(read_schema_list "$CUSTOM"; read_schema_list "$RIME_DIR/default.yaml")
  [ ${#seen[@]} -eq 0 ] && printf '  （读不到，请检查 default.yaml）\n'
}

manage_schemas(){
  local -a avail=()
  local f
  while IFS= read -r f; do
    avail+=("$(basename "$f" .schema.yaml)")
  done < <(find "$RIME_DIR" -maxdepth 1 -name '*.schema.yaml' 2>/dev/null | sort)

  if [ ${#avail[@]} -eq 0 ]; then
    warn "目录里没有 *.schema.yaml 输入方案文件"
    return
  fi

  local -A on=()
  local s
  while IFS= read -r s; do [ -n "$s" ] && on[$s]=1; done \
    < <(read_schema_list "$CUSTOM"; read_schema_list "$RIME_DIR/default.yaml")

  info "输入方案（[x] 表示已启用）"
  local i
  for i in "${!avail[@]}"; do
    printf '  [%s] %2d) %s\n' "$([ -n "${on[${avail[$i]}]:-}" ] && echo x || echo ' ')" "$((i+1))" "${avail[$i]}"
  done

  printf '\n输入要启用的编号（空格分隔），直接回车取消：'
  local line=""
  read -r line
  [ -z "$line" ] && return

  local chosen="" n
  for n in $line; do
    case $n in *[!0-9]*) warn "忽略无效编号：$n"; continue;; esac
    if [ "$n" -ge 1 ] && [ "$n" -le ${#avail[@]} ]; then
      chosen="$chosen ${avail[$((n-1))]}"
    fi
  done
  [ -z "$chosen" ] && { warn "没有选中任何方案"; return; }

  write_schema_list "$chosen" && ok "已更新方案列表"
}

set_page_size(){
  local n="" cur
  cur=$(awk '/^  menu\/page_size:/ {print $NF; exit}' "$CUSTOM" 2>/dev/null)
  printf '当前 %s，输入候选词个数 1-9（回车取消）：' "${cur:-默认 5}"
  read -r n
  [ -z "$n" ] && return
  case $n in *[!0-9]*) warn "只能输入数字"; return;; esac
  if [ "$n" -lt 1 ] || [ "$n" -gt 9 ]; then warn "范围是 1 到 9"; return; fi
  set_patch_scalar menu/page_size "$n" && ok "候选词个数已设为 $n"
}

show_log(){
  local f
  f=$(ls -t /tmp/rime*.log "$RIME_DIR"/rime.log 2>/dev/null | head -n1)
  if [ -z "$f" ]; then
    warn "没找到日志。可试：fcitx5-diagnose | grep -i rime"
    return
  fi
  info "日志文件：$f"
  tail -n 30 "$f"
}

edit_custom(){
  ensure_custom
  local ed="${EDITOR:-${VISUAL:-vi}}"
  $ed "$CUSTOM"
}

redeploy(){
  if pgrep -f fcitx5 >/dev/null 2>&1 && command -v fcitx5-remote >/dev/null 2>&1; then
    fcitx5-remote -r >/dev/null 2>&1 && { ok "已重启 fcitx5，Rime 正在重新部署"; return; }
  fi
  if pgrep -f ibus-daemon >/dev/null 2>&1; then
    ibus restart >/dev/null 2>&1 && { ok "已重启 ibus，Rime 正在重新部署"; return; }
  fi
  if pgrep -f fcitx >/dev/null 2>&1; then
    warn "无法自动部署，请在输入法面板右键选「部署」，或切到 Rime 后按 Ctrl+\` 选「部署」"
    return
  fi
  warn "输入法没在运行，先启动输入法再重新部署"
}

# ---------- 自检 ----------
self_test(){
  local tmp
  tmp=$(mktemp -d) || return 1
  RIME_DIR="$tmp"; CUSTOM="$tmp/default.custom.yaml"

  set_patch_scalar menu/page_size 7 || { err "写入失败"; return 1; }
  set_patch_scalar menu/page_size 9 || { err "改写入失败"; return 1; }
  write_schema_list "luna_pinyin luna_pinyin_simp" || { err "方案写入失败"; return 1; }

  [ "$(grep -c 'menu/page_size' "$CUSTOM")" = "1" ] || { err "自检失败：键重复写入"; return 1; }
  grep -q '^  menu/page_size: 9$' "$CUSTOM" || { err "自检失败：值未更新"; return 1; }
  grep -q '^    - schema: luna_pinyin_simp$' "$CUSTOM" || { err "自检失败：方案列表缺项"; return 1; }
  [ "$(grep -c '^patch:$' "$CUSTOM")" = "1" ] || { err "自检失败：patch 段重复"; return 1; }

  rm -rf "$tmp"
  ok "自检通过"
}

# ---------- 主流程 ----------
main_menu(){
  while :; do
    printf '\n'
    info "====== 中州韵配置编辑器 ======"
    printf ' 1) 查看当前设置\n'
    printf ' 2) 启用 / 停用输入方案\n'
    printf ' 3) 设置候选词个数\n'
    printf ' 4) 查看部署日志（排错）\n'
    printf ' 5) 手动编辑 default.custom.yaml\n'
    printf ' 6) 备份当前配置\n'
    printf ' 7) 重新部署 Rime\n'
    printf ' 0) 退出\n'
    printf '请选择：'
    local c=""
    read -r c
    case $c in
      1) show_summary; pause ;;
      2) manage_schemas; pause ;;
      3) set_page_size; pause ;;
      4) show_log; pause ;;
      5) edit_custom ;;
      6) backup_custom && ok "已备份（同目录下 *.bak.* 文件）"; pause ;;
      7) redeploy; pause ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main(){
  if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

  if ! detect_rime_dir; then
    warn "没有自动找到 Rime 配置目录"
    printf '请手动输入（例如 ~/.local/share/fcitx5/rime），回车退出：'
    local d=""
    read -r d
    [ -n "$d" ] && [ -d "$d" ] || { err "目录不存在"; exit 1; }
    RIME_DIR="$d"
  fi
  CUSTOM="$RIME_DIR/default.custom.yaml"
  ok "配置目录：$RIME_DIR"
  main_menu
}
main "$@"
