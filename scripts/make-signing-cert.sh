#!/bin/sh
# 生成本地代码签名证书「Polish Local Signing」并导入登录钥匙串（只需一次）。
# 作用：签名身份固定为「bundle id + 证书」，重建后辅助功能、输入监控授权不失效。
# 证书只供 codesign 使用；Polish 运行时不读写钥匙串（API Key 存本地 keys.json）。
# 证书不加入系统信任，只供本机签名；首次签名时系统会询问是否允许 codesign 使用该密钥，选「始终允许」。
# 撤销：钥匙串访问 → 登录 → 删除「Polish Local Signing」证书与密钥。
set -eu
if security find-identity -p codesigning | grep -q '"Polish Local Signing"'; then
    echo "已存在 Polish Local Signing"; exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Polish Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -config "$dir/cert.cnf"
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/p.p12" -passout "pass:$pass" -name "Polish Local Signing"
security import "$dir/p.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
echo "✓ 已导入 Polish Local Signing"
