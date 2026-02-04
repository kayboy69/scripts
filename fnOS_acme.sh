#!/bin/bash

# ================= 配置区域 =================
# 1. SSL证书域名 (必填!)
export DOMAIN=""

# 2. DNS 提供商配置
export DNS="dns_dp" # 腾讯云dnspod
export DP_Id=""
export DP_Key=""
# 如果是阿里云，请解除下面注释并填写
# export DNS="dns_ali"
# export Ali_Key=""
# export Ali_Secret=""

# 3. 其他配置
ACME_DIR="/opt/acme/acme.sh"
SSLS_DIR="/usr/trim/var/trim_connect/ssls"
DNS_SLEEP="60"
CERT_SERVER="letsencrypt"
ReloadCMD="systemctl restart webdav.service smbftpd.service trim_nginx.service"
# ===========================================

# --- 安全检查 ---
if [ -z "$DOMAIN" ]; then
    echo "错误: 请在脚本开头填写 DOMAIN (域名) 变量！"
    exit 1
fi

if [ ! -f "$ACME_DIR/acme.sh" ]; then
    echo "错误: 未找到 acme.sh，请先安装。"
    exit 1
fi

# 获取脚本开始运行时间戳
TT=$(date +%s%3N)

# 制作证书
echo "正在申请/更新证书..."
case ${CERT_SERVER} in
    letsencrypt)
        ${ACME_DIR}/acme.sh --force --log --issue --server ${CERT_SERVER} --dns ${DNS} --dnssleep ${DNS_SLEEP} -d "${DOMAIN}" -d "*.${DOMAIN}" && echo -e "证书制作成功" || { echo -e "制作证书失败，脚本退出..."; exit 1; }
        ;;
    zerossl)
        # 如果需要zerossl，请自行补充相关参数变量
        ${ACME_DIR}/acme.sh --register-account -m ${Email} --server ${CERT_SERVER} --eab-kid ${EAB_kid} --eab-hmac-key ${EAB_hmac_key} --issue --dns ${DNS} --dnssleep ${DNS_SLEEP} -d "${DOMAIN}" -d "*.${DOMAIN}" && echo -e "证书制作成功" || { echo -e "制作证书失败，脚本退出..."; exit 1; }
        ;;
    *)
        echo -e "证书服务商配置错误"
        exit 1
        ;;
esac

# 计算时间戳 (逻辑保持原版，适配 fnOS 数据库要求)
CertCreateTime="$(${ACME_DIR}/acme.sh --info -d "${DOMAIN}" | grep CertCreateTimeStr= | awk -F= '{print $2}' | sed 's|T| |g' | sed 's|Z||g')"
NextRenewTime="$(${ACME_DIR}/acme.sh --info -d "${DOMAIN}" | grep Le_NextRenewTimeStr= | awk -F= '{print $2}' | sed 's|T| |g' | sed 's|Z||g')"
CERT_CREATE=$(date -d "${CertCreateTime} 7 hour" +%s)
CERT_CREATE_TT=$(date -d "${CertCreateTime} 7 hour" +%s%3N)
CERT_RENEW=$(date -d "${NextRenewTime} 1 month 7 hour" +%s)
CERT_RENEW_TT=$(date -d "${NextRenewTime} 1 month 7 hour" +%s%3N)

# 创建存放目录
DOMAIN_SSL_DIR="${SSLS_DIR}/${DOMAIN}/${CERT_CREATE}"
mkdir -p "${DOMAIN_SSL_DIR}"

# 定义证书文件的最终路径
CRT_FILE="${DOMAIN_SSL_DIR}/${DOMAIN}.crt"
KEY_FILE="${DOMAIN_SSL_DIR}/${DOMAIN}.key"
FULLCHAIN_FILE="${DOMAIN_SSL_DIR}/fullchain.crt"
CA_FILE="${DOMAIN_SSL_DIR}/issuer_certificate.crt"

# 安装证书到指定目录
${ACME_DIR}/acme.sh --install-cert -d "${DOMAIN}" \
    --cert-file "${CRT_FILE}" \
    --key-file "${KEY_FILE}" \
    --fullchain-file "${FULLCHAIN_FILE}" \
    --ca-file "${CA_FILE}" \
    --reloadcmd "${ReloadCMD}" \
    && echo -e "证书安装成功" || { echo -e "证书安装失败，脚本退出..."; exit 1; }

# 配置权限
chmod 755 "${DOMAIN_SSL_DIR}"/*.{crt,key}

# 获取证书信息供数据库使用
CERT_ISSUED_BY=$(openssl x509 -in "${CRT_FILE}" -noout -issuer | awk -F' = ' '{print $4}')
SIG_ALGO=$(openssl x509 -in "${CRT_FILE}" -noout -text | awk '/Signature Algorithm/ {print $3}' | awk 'END {print}')

shopt -s nocasematch
case $SIG_ALGO in
    *RSA*) ALGO_TYPE="RSA" ;;
    *ECDSA*) ALGO_TYPE="ECDSA" ;;
    *ECC*) ALGO_TYPE="ECC" ;;
    *SM2*) ALGO_TYPE="SM2" ;;
    *) ALGO_TYPE="UNKNOW" ;;
esac
shopt -u nocasematch

# --- 数据库操作 (PSQL) ---
echo "正在更新数据库..."
DB_CHECK=$(psql -t -A -U postgres -d trim_connect -c "SELECT domain FROM cert WHERE domain = '${DOMAIN}';" | sed '/^\s*$/d')

if [ ! -z "$DB_CHECK" ]; then
    # 更新现有记录
    psql -U postgres -d trim_connect -c "UPDATE cert SET valid_from = ${CERT_CREATE_TT}, valid_to = ${CERT_RENEW_TT}, encrypt_type = '${ALGO_TYPE}', issued_by = '${CERT_ISSUED_BY}', last_renew_time = ${TT}, des = '由acme.sh自动生成的证书', private_key = '${KEY_FILE}', certificate = '${CRT_FILE}', issuer_certificate = '${CA_FILE}', status = 'suc', created_time = ${TT}, updated_time = ${TT} WHERE domain = '${DOMAIN}';" >/dev/null 2>&1 && echo -e "数据库: 更新成功" || { echo -e "数据库: 更新失败"; exit 1; }
else
    # 插入新记录
    DOMAIN_ID=$[$(psql -t -A -U postgres -d trim_connect -c "SELECT id FROM cert ORDER BY id ASC;" | awk 'END {print}')+1]
    psql -U postgres -d trim_connect -c "INSERT INTO cert VALUES (${DOMAIN_ID}, '${DOMAIN}', '*.${DOMAIN},${DOMAIN}', ${CERT_CREATE_TT}, ${CERT_RENEW_TT}, '${ALGO_TYPE}', '${CERT_ISSUED_BY}', ${TT}, '由acme.sh自动生成的证书', 0, null, 'upload', null, '${KEY_FILE}', '${CRT_FILE}', '${CA_FILE}', 'suc', ${TT}, ${TT});" >/dev/null 2>&1 && echo -e "数据库: 插入成功" || { echo -e "数据库: 插入失败"; exit 1; }
fi

# --- 更新 NGINX 配置 (Python 优化版) ---
echo "正在更新 Nginx 配置文件..."
\cp -rfL /usr/trim/etc/network_gateway_cert.conf /usr/trim/etc/network_gateway_cert.conf.${TT}.bak

# 通过环境变量将参数传递给 Python，避免特殊字符导致脚本崩溃
export PY_CONFIG_FILE="/usr/trim/etc/network_gateway_cert.conf"
export PY_DOMAIN="${DOMAIN}"
export PY_CERT="${FULLCHAIN_FILE}"
export PY_KEY="${KEY_FILE}"

python3 -c "
import json
import sys
import os

config_file = os.environ['PY_CONFIG_FILE']
domain = os.environ['PY_DOMAIN']
cert_path = os.environ['PY_CERT']
key_path = os.environ['PY_KEY']

try:
    data = []
    if os.path.exists(config_file) and os.path.getsize(config_file) > 0:
        with open(config_file, 'r') as f:
            try:
                data = json.load(f)
                if not isinstance(data, list): data = []
            except:
                data = []

    found = False
    for item in data:
        if item.get('host') == domain:
            item['cert'] = cert_path
            item['key'] = key_path
            found = True
            print(f'Python: 已更新域名 {domain} 的路径')
            break
    
    if not found:
        data.append({'host': domain, 'cert': cert_path, 'key': key_path})
        print(f'Python: 新增域名 {domain}')

    with open(config_file, 'w') as f:
        json.dump(data, f, indent=4)

except Exception as e:
    print(f'Python Error: {e}')
    sys.exit(1)
"

if [ $? -ne 0 ]; then
    echo "Nginx 配置更新失败，脚本退出"
    exit 1
fi

# --- 清理与重启 ---
echo "清理旧文件并重启服务..."
# 删除90天前的旧备份
find ${SSLS_DIR}/"${DOMAIN}"/ -mtime +90 -type d -exec rm -rf {} \; >/dev/null 2>&1
find /usr/trim/etc/ -mtime +90 -name "network_gateway_cert.conf.*.bak" -exec rm -rf {} \; >/dev/null 2>&1

${ReloadCMD}
echo "所有操作完成！"

# 写入变量文件 (保留原脚本逻辑)
echo -e "DOMAIN=${DOMAIN}" > "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "CERT_CREATE_TT=${CERT_CREATE_TT}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "CERT_RENEW_TT=${CERT_RENEW_TT}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "ALGO_TYPE=${ALGO_TYPE}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "CERT_ISSUED_BY=${CERT_ISSUED_BY}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "TT=${TT}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
echo -e "DOMAIN_SSL_DIR=${DOMAIN_SSL_DIR}" >> "${DOMAIN_SSL_DIR}/sslpath.conf"
