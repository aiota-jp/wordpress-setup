#!/usr/bin/env bash
#
# setup_wordpress.sh
# -----------------------------------------------------------------------------
# AlmaLinux 上で WordPress を自力構築するための自動化スクリプト（記事のセクション
# 1〜7 に対応）。ブラウザからの初期設定（セクション8以降）は手動で行います。
#
# 実行内容:
#   1. Apache (httpd) のインストール・起動・自動起動
#   2. PHP と関連パッケージのインストール
#   3. MariaDB のインストール・起動・自動起動
#   4. WordPress 用データベース／ユーザーの作成
#   5. WordPress のダウンロードと展開
#   6. /var/www/html への配置と所有者・権限設定
#   7. SELinux Boolean / コンテキスト、firewalld のポート開放
#
# 特徴:
#   - 記事の方針どおり「まず現在の環境を確認 → 環境に合わせて実行」を意識
#   - できるだけ冪等（再実行しても壊れにくい）に作成
#   - root 権限で実行する前提
#
# 使い方:
#   sudo ./setup_wordpress.sh
#
# 環境変数で上書き可能（例）:
#   WP_DB_NAME=wordpress WP_DB_USER=wp WP_DB_PASS='StrongPass!' sudo -E ./setup_wordpress.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# --------------------------------------------------------------------------- #
# 設定（必要に応じて環境変数で上書き）
# --------------------------------------------------------------------------- #
WP_DB_NAME="${WP_DB_NAME:-wordpress}"
WP_DB_USER="${WP_DB_USER:-wp}"
WP_DB_PASS="${WP_DB_PASS:-}"          # 空ならスクリプト内で生成/入力を促す
WP_DB_HOST="${WP_DB_HOST:-localhost}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
WP_DL_URL="${WP_DL_URL:-https://wordpress.org/latest.tar.gz}"
WORK_DIR="${WORK_DIR:-/tmp/wp}"
ALLOW_OUTBOUND="${ALLOW_OUTBOUND:-1}"  # 1 なら httpd_can_network_connect も有効化

# --------------------------------------------------------------------------- #
# ログ用ヘルパー
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }

die() { err "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# 事前チェック
# --------------------------------------------------------------------------- #
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "root 権限で実行してください（例: sudo $0）"
  fi
}

detect_os() {
  log "OS バージョンを確認します"
  if [[ -f /etc/almalinux-release ]]; then
    cat /etc/almalinux-release
  elif [[ -f /etc/redhat-release ]]; then
    cat /etc/redhat-release
    warn "AlmaLinux 以外の RHEL 系ディストリビューションの可能性があります"
  else
    warn "AlmaLinux/RHEL 系ではない可能性があります。処理を続行しますが注意してください"
  fi
}

# --------------------------------------------------------------------------- #
# 1. Apache
# --------------------------------------------------------------------------- #
install_apache() {
  log "[1/7] Apache (httpd) をインストールします"
  dnf -y install httpd
  systemctl enable --now httpd
  systemctl is-active --quiet httpd && ok "httpd は起動しています" || die "httpd の起動に失敗しました"
}

# --------------------------------------------------------------------------- #
# 2. PHP
# --------------------------------------------------------------------------- #
install_php() {
  log "[2/7] PHP をインストールします"
  # 記事の方針: まず既定バージョンを確認する
  log "インストール可能な PHP の既定バージョン:"
  dnf info php 2>/dev/null | grep -E '^(Name|Version)' || true

  # php-json は PHP 8.0 以降 php-common に統合されるため、存在するときだけ追加する
  local pkgs=(php php-mysqlnd php-devel)
  if dnf info php-json >/dev/null 2>&1; then
    pkgs+=(php-json)
  else
    log "php-json は本体に統合済みのため個別インストールを省略します"
  fi

  dnf -y install "${pkgs[@]}"
  systemctl restart httpd
  ok "PHP バージョン: $(php -v | head -n1)"
}

# --------------------------------------------------------------------------- #
# 3. MariaDB
# --------------------------------------------------------------------------- #
install_mariadb() {
  log "[3/7] MariaDB をインストールします"
  log "インストール可能な MariaDB の既定バージョン:"
  dnf info mariadb-server 2>/dev/null | grep -E '^(Name|Version)' || true

  dnf -y install mariadb mariadb-server
  systemctl enable --now mariadb
  systemctl is-active --quiet mariadb && ok "mariadb は起動しています" || die "mariadb の起動に失敗しました"
  ok "MariaDB バージョン: $(mariadb --version)"
}

# --------------------------------------------------------------------------- #
# 4. WordPress 用データベース
# --------------------------------------------------------------------------- #
ensure_db_password() {
  if [[ -z "${WP_DB_PASS}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      WP_DB_PASS="$(openssl rand -base64 18)"
      warn "WP_DB_PASS が未指定のため、自動生成しました（下に表示します）"
    else
      read -r -s -p "WordPress 用 DB パスワードを入力してください: " WP_DB_PASS
      echo
      [[ -n "${WP_DB_PASS}" ]] || die "パスワードが空です"
    fi
  fi
}

create_database() {
  log "[4/7] WordPress 用データベースを作成します"
  ensure_db_password

  # localhost の root（unix_socket 認証）でログインできる前提。
  # SQL 内でユーザー名/パスワードを安全に埋め込むため、識別子と文字列を分けて扱う。
  # 注: mariadb クライアントへヒアドキュメントで渡す。
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'${WP_DB_HOST}' IDENTIFIED BY '${WP_DB_PASS}';
ALTER USER '${WP_DB_USER}'@'${WP_DB_HOST}' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'${WP_DB_HOST}';
FLUSH PRIVILEGES;
SQL

  # 作成確認
  if mariadb -N -e "SHOW DATABASES LIKE '${WP_DB_NAME}';" | grep -q "${WP_DB_NAME}"; then
    ok "データベース '${WP_DB_NAME}' を確認しました"
  else
    die "データベース '${WP_DB_NAME}' の作成に失敗しました"
  fi
}

# --------------------------------------------------------------------------- #
# 5. WordPress ダウンロード
# --------------------------------------------------------------------------- #
download_wordpress() {
  log "[5/7] WordPress をダウンロードします"
  mkdir -p "${WORK_DIR}"
  cd "${WORK_DIR}"

  if ! command -v wget >/dev/null 2>&1; then
    log "wget が無いためインストールします"
    dnf -y install wget
  fi

  wget -q -O latest.tar.gz "${WP_DL_URL}"
  tar xzf latest.tar.gz
  [[ -d "${WORK_DIR}/wordpress" ]] || die "WordPress の展開に失敗しました"
  ok "WordPress を展開しました: ${WORK_DIR}/wordpress"
}

# --------------------------------------------------------------------------- #
# 6. 公開ディレクトリへ配置
# --------------------------------------------------------------------------- #
deploy_wordpress() {
  log "[6/7] WordPress を ${WEB_ROOT} へ配置します"
  mkdir -p "${WEB_ROOT}"

  # 既存の index.html（httpd のテストページ）が邪魔になる場合は退避
  if [[ -f "${WEB_ROOT}/index.html" ]]; then
    mv "${WEB_ROOT}/index.html" "${WEB_ROOT}/index.html.bak.$(date +%s)"
    warn "既存の index.html を退避しました"
  fi

  # ドットファイルも含めてコピー
  cp -a "${WORK_DIR}/wordpress/." "${WEB_ROOT}/"

  chown -R apache:apache "${WEB_ROOT}"
  # ディレクトリ 755 / ファイル 644 を基本とする（記事の chmod -R +w より安全な既定）
  find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
  find "${WEB_ROOT}" -type f -exec chmod 644 {} \;
  ok "配置と所有者・権限設定が完了しました"
}

# --------------------------------------------------------------------------- #
# 7. SELinux / Firewall
# --------------------------------------------------------------------------- #
configure_selinux() {
  log "[7/7] SELinux を確認・設定します"
  if ! command -v getenforce >/dev/null 2>&1; then
    warn "SELinux ツールが見つかりません。スキップします"
    return
  fi

  local mode
  mode="$(getenforce || echo Unknown)"
  log "SELinux モード: ${mode}"

  if [[ "${mode}" == "Disabled" ]]; then
    warn "SELinux は無効です。Boolean/コンテキスト設定はスキップします"
    return
  fi

  # DB 接続を許可（localhost DB では不要な場合もあるが安全側で有効化）
  setsebool -P httpd_can_network_connect_db 1 || warn "httpd_can_network_connect_db の設定に失敗"
  if [[ "${ALLOW_OUTBOUND}" == "1" ]]; then
    setsebool -P httpd_can_network_connect 1 || warn "httpd_can_network_connect の設定に失敗"
  fi

  # wp-content を書き込み可能コンテキストに
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_rw_content_t "${WEB_ROOT}/wp-content(/.*)?" 2>/dev/null || \
      warn "fcontext は既に登録済みか、追加に失敗しました"
  else
    log "semanage が無いため policycoreutils-python-utils を導入します"
    dnf -y install policycoreutils-python-utils || warn "policycoreutils-python-utils の導入に失敗"
    if command -v semanage >/dev/null 2>&1; then
      semanage fcontext -a -t httpd_sys_rw_content_t "${WEB_ROOT}/wp-content(/.*)?" 2>/dev/null || \
        warn "fcontext の追加に失敗しました"
    fi
  fi
  restorecon -Rv "${WEB_ROOT}" >/dev/null 2>&1 || true
  ok "SELinux の設定が完了しました"
}

configure_firewall() {
  log "firewalld のポート（http/https）を開放します"
  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld が動いていません。ポート開放をスキップします（さくらVPS側フィルタは別途確認）"
    return
  fi
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
  ok "http/https を許可しました: $(firewall-cmd --list-services)"
}

# --------------------------------------------------------------------------- #
# 完了メッセージ
# --------------------------------------------------------------------------- #
print_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<EOF

============================================================
 セットアップ完了（セクション1〜7）
============================================================
 DB 名           : ${WP_DB_NAME}
 DB ユーザー      : ${WP_DB_USER}
 DB ホスト        : ${WP_DB_HOST}
 DB パスワード     : ${WP_DB_PASS}
 公開ディレクトリ  : ${WEB_ROOT}

 次のステップ（ブラウザで手動 / 記事のセクション8以降）:
   http://${ip:-サーバーのIPv4アドレス}/wp-admin/install.php

 上記の DB 情報を入力してセットアップを進めてください。
 （テーブル接頭辞は wp_ が既定）
============================================================
EOF
  warn "DB パスワードは安全な場所に保管し、この出力は残さないでください"
}

# --------------------------------------------------------------------------- #
# メイン
# --------------------------------------------------------------------------- #
main() {
  require_root
  detect_os
  install_apache
  install_php
  install_mariadb
  create_database
  download_wordpress
  deploy_wordpress
  configure_selinux
  configure_firewall
  print_summary
}

main "$@"
