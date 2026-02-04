#!/bin/bash

# 获取脚本开始运行时间戳
TT=$(date +%s%3N)

# 下载并安装 acme.sh
#mkdir -p /opt/acme && cd /opt/acme && git clone https://gitee.com/neilpang/acme.sh.git && cd acme.sh && ./acme.sh --install -m my@server.com

# acme.sh 脚本路径
ACME_DIR="/opt/acme/acme.sh"

# SSL证书域名
export DOMAIN=""

# DNS类型，dns_ali dns_dp dns_gd dns_aws dns_cf 等，具体支持列表详见 https://github.com/acmesh-official/acme.sh/wiki/dnsapi
export DNS="dns_dp"

# 腾讯云dnspod的API秘钥，其他DNS请自行修改变量名及替换脚本
export DP_Id=""
export DP_Key=""

# DNS API 生效等待时间 值(单位：秒)，一般120即可
# 某些域名服务商的API生效时间较大，需要将这个值加大(比如900)
DNS_SLEEP="60"

# 证书服务商，zerossl 和 letsencrypt，我使用letsencrypt，使用zerossl还需要注册
CERT_SERVER="letsencrypt"

# zerossl注册邮箱及EAB，访问 https://app.zerossl.com/developer 获取账号 EAB_kid & EAB_hmac_key
#export Email=
#export EAB_kid=
#export EAB_hmac_key=

# 飞牛OS SSL证书路径
SSLS_DIR="/usr/trim/var/trim_connect/ssls"

# 飞牛OS重启服务命令行
ReloadCMD="systemctl restart webdav.service smbftpd.service trim_nginx.service"

# 制作证书
case ${CERT_SERVER} in
    letsencrypt)
        ${ACME_DIR}/acme.sh --force --log --issue --server ${CERT_SERVER} --dns ${DNS} --dnssleep ${DNS_SLEEP} -d "${DOMAIN}" -d "*.${DOMAIN}" && echo -e "证书制作成功" || { echo -e "制作证书失败，脚本退出. . ."; exit 1; }
        ;;
    zerossl)
        ${ACME_DIR}/acme.sh --register-account -m ${Email} --server ${CERT_SERVER} --eab-kid ${EAB_kid} --eab-hmac-key ${EAB_hmac_key} --issue --dns ${DNS} --dnssleep ${DNS_SLEEP} -d "${DOMAIN}" -d "*.${DOMAIN}" && echo -e "证书制作成功" || { echo -e "制作证书失败，脚本退出. . ."; exit 1; }
        ;;
    *)
        echo -e "证书服务商未知或填写错误"
        exit 1
        ;;
esac

# 获取证书详细时间戳并创建目录
CertCreateTime="$(${ACME_DIR}/acme.sh --info -d "${DOMAIN}" | grep CertCreateTimeStr= | awk -F= '{print $2}' | sed 's|T| |g' | sed 's|Z||g')"
NextRenewTime="$(${ACME_DIR}/acme.sh --info -d "${DOMAIN}" | grep Le_NextRenewTimeStr= | awk -F= '{print $2}' | sed 's|T| |g' | sed 's|Z||g')"
CERT_CREATE=$(date -d "${CertCreateTime} 7 hour" +%s)
CERT_CREATE_TT=$(date -d "${CertCreateTime} 7 hour" +%s%3N)
CERT_RENEW=$(date -d "${NextRenewTime} 1 month 7 hour" +%s)
CERT_RENEW_TT=$(date -d "${NextRenewTime} 1 month 7 hour" +%s%3N)
mkdir -p ${SSLS_DIR}/"${DOMAIN}"/${CERT_CREATE}
DOMAIN_SSL_DIR=${SSLS_DIR}/"${DOMAIN}"/${CERT_CREATE}

# 安装证书到域名证书目录，acme.sh部署API暂未支持飞牛，详见 https://github.com/acmesh-official/acme.sh/wiki/deployhooks
${ACME_DIR}/acme.sh --install-cert -d "${DOMAIN}" --cert-file ${DOMAIN_SSL_DIR}/"${DOMAIN}".crt --key-file ${DOMAIN_SSL_DIR}/"${DOMAIN}".key --fullchain-file ${DOMAIN_SSL_DIR}/fullchain.crt --ca-file ${DOMAIN_SSL_DIR}/issuer_certificate.crt --reloadcmd "${ReloadCMD}" && echo -e "证书安装成功" || { echo -e "制作安装失败，脚本退出. . ."; exit 1; }

# 配置证书文件权限
chmod 755 ${DOMAIN_SSL_DIR}/"${DOMAIN}".crt
chmod 755 ${DOMAIN_SSL_DIR}/"${DOMAIN}".key
chmod 755 ${DOMAIN_SSL_DIR}/fullchain.crt
chmod 755 ${DOMAIN_SSL_DIR}/issuer_certificate.crt

# 获取证书颁发者信息
CERT_ISSUED_BY=$(openssl x509 -in ${DOMAIN_SSL_DIR}/"${DOMAIN}".crt -noout -issuer | awk -F' = ' '{print $4}')

# 获取证书加密类型信息
SIG_ALGO=$(openssl x509 -in ${DOMAIN_SSL_DIR}/"${DOMAIN}".crt -noout -text | awk '/Signature Algorithm/ {print $3}' | awk 'END {print}')
shopt -s nocasematch
case $SIG_ALGO in
    *RSA*)
        ALGO_TYPE="RSA"
        ;;
    *ECDSA*)
        ALGO_TYPE="ECDSA"
        ;;
    *ECC*)
        ALGO_TYPE="ECC"
        ;;
    *SM2*)
        ALGO_TYPE="SM2"
        ;;
    *)
        ALGO_TYPE="UNKNOW"
        ;;
esac
shopt -u nocasematch

# 新增或更新飞牛OS证书数据库信息
if [ ! -z $(psql -t -A -U postgres -d trim_connect -c "SELECT domain FROM cert WHERE domain = '"${DOMAIN}"';" | sed '/^\s*$/d') ]; then
    # 飞牛OS更新数据库证书信息
    psql -U postgres -d trim_connect -c "UPDATE cert SET valid_from = ${CERT_CREATE_TT}, valid_to = ${CERT_RENEW_TT}, encrypt_type = '${ALGO_TYPE}', issued_by = '${CERT_ISSUED_BY}', last_renew_time = ${TT}, des = '由acme.sh自动生成的证书', private_key = '${DOMAIN_SSL_DIR}/\"${DOMAIN}\".key', certificate = '${DOMAIN_SSL_DIR}/\"${DOMAIN}\".crt', issuer_certificate = '${DOMAIN_SSL_DIR}/issuer_certificate.crt', status = 'suc', created_time = ${TT}, updated_time = ${TT} WHERE domain = '"${DOMAIN}"';" >/dev/null 2>&1 && echo -e "证书信息更新成功" || { echo -e "证书信息更新失败，脚本退出. . ."; exit 1; }
else
    # 飞牛OS插入数据库证书信息
    DOMAIN_ID=$[$(psql -t -A -U postgres -d trim_connect -c "SELECT id FROM cert ORDER BY id ASC;" | awk 'END {print}')+1]
    psql -U postgres -d trim_connect -c "INSERT INTO cert VALUES ("${DOMAIN_ID}", '"${DOMAIN}"', '*.\"${DOMAIN}\",\"${DOMAIN}\"', ${CERT_CREATE_TT}, ${CERT_RENEW_TT}, '${ALGO_TYPE}', '${CERT_ISSUED_BY}', ${TT}, '由acme.sh自动生成的证书', 0, null, 'upload', null, '${DOMAIN_SSL_DIR}/\"${DOMAIN}\".key', '${DOMAIN_SSL_DIR}/\"${DOMAIN}\".crt', '${DOMAIN_SSL_DIR}/issuer_certificate.crt', 'suc', ${TT}, ${TT});" >/dev/null 2>&1 && echo -e "证书信息插入成功" || { echo -e "证书信息插入失败，脚本退出. . ."; exit 1; }
fi

# 更新飞牛OS NGINX 配置文件
\cp -rfL /usr/trim/etc/network_gateway_cert.conf /usr/trim/etc/network_gateway_cert.conf.${TT}.bak
NETWORK_GATEWAY_CERT="{\"host\":\""${DOMAIN}"\",\"cert\":\"${DOMAIN_SSL_DIR}/fullchain.crt\",\"key\":\"${DOMAIN_SSL_DIR}/\"${DOMAIN}\".key\"},"
grep -qE ""${DOMAIN}"" /usr/trim/etc/network_gateway_cert.conf
if [ $? -eq 0 ]; then
    sed -i "s|{\"host\":.*\/usr\/.*\"${DOMAIN}\".*},|${NETWORK_GATEWAY_CERT}|g" /usr/trim/etc/network_gateway_cert.conf
else
    awk '{gsub(/^./,""); print}' /usr/trim/etc/network_gateway_cert.conf > /tmp/fn
    sed -i "1i[${NETWORK_GATEWAY_CERT}" /tmp/fn
    sed -i ':a;N;$!ba;s/\n//g' /tmp/fn
    \cp -rfL /tmp/fn /usr/trim/etc/network_gateway_cert.conf
    rm -rf /tmp/fn
fi
grep -qE "${DOMAIN_SSL_DIR}" /usr/trim/etc/network_gateway_cert.conf && echo -e "更新nginx配置成功" || { echo -e "更新nginx配置失败，脚本退出. . ."; exit 1; }

# 飞牛OS删除无效证书
find ${SSLS_DIR}/"${DOMAIN}"/ -mtime +90 -type d -exec rm -rf {} \; >/dev/null 2>&1
find /usr/trim/etc/ -mtime +90 -name "network_gateway_cert.conf.*.bak" -exec rm -rf {} \; >/dev/null 2>&1

${ReloadCMD}

# 飞牛OS写入变量配置，方便其他有需要的调用，可自行发挥想象
echo -e "DOMAIN=${DOMAIN}" > ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "CERT_CREATE_TT=${CERT_CREATE_TT}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "CERT_RENEW_TT=${CERT_RENEW_TT}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "ALGO_TYPE=${ALGO_TYPE}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "CERT_ISSUED_BY=${CERT_ISSUED_BY}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "TT=${TT}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
echo -e "DOMAIN_SSL_DIR=${DOMAIN_SSL_DIR}" >> ${SSLS_DIR}/"${DOMAIN}"/sslpath.conf
