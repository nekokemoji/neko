#!/usr/bin/env bash

# Client subscription format renderers for sing-box, Mihomo, Stash, and
# Shadowrocket. Loaded through lib/render.sh.

render_sing_box_client() {
  local target="$1" server="$2" dns_server="$3" dns_mode="$4"
  local dns_strategy="$5" rejected_ip_version="$6"
  local route_hy2_start="$7" route_hy2_end="$8" route_tuic_port="$9"
  local route_ss_port="${10}" route_anytls_port="${11}" route_trojan_port="${12}"
  local route_vision_port="${13}" route_anyreality_port="${14:-null}"
  local route_anyreality_enabled="${15:-false}"

  jq -n \
    --arg domain "$DOMAIN" \
    --arg server "$server" \
    --arg dns_server "$dns_server" \
    --arg dns_mode "$dns_mode" \
    --arg dns_strategy "$dns_strategy" \
    --argjson rejected_ip_version "$rejected_ip_version" \
    --arg hy2_ports "${route_hy2_start}:${route_hy2_end}" \
    --arg hy2_password "$HY2_PASSWORD" \
    --arg hy2_obfs_password "$HY2_OBFS_PASSWORD" \
    --argjson tuic_port "$route_tuic_port" \
    --arg tuic_uuid "$TUIC_UUID" \
    --arg tuic_password "$TUIC_PASSWORD" \
    --argjson ss_port "$route_ss_port" \
    --arg ss_password "$SS_PASSWORD" \
    --argjson anytls_port "$route_anytls_port" \
    --arg anytls_password "$ANYTLS_PASSWORD" \
    --argjson trojan_port "$route_trojan_port" \
    --arg trojan_password "$TROJAN_PASSWORD" \
    --argjson vision_port "$route_vision_port" \
    --arg vision_uuid "$VISION_UUID" \
    --arg vision_public_key "$VISION_PUBLIC_KEY" \
    --arg vision_short_id "$VISION_SHORT_ID" \
    --argjson anyreality_enabled "$route_anyreality_enabled" \
    --argjson anyreality_port "$route_anyreality_port" \
    --arg anyreality_password "$ANYREALITY_PASSWORD" \
    --arg anyreality_public_key "$ANYREALITY_PUBLIC_KEY" \
    --arg anyreality_short_id "$ANYREALITY_SHORT_ID" \
    '{
      log: {
        level: "info",
        timestamp: true
      },
      dns: {
        servers: [(if $dns_mode == "akdns" then {
          type: "tcp",
          tag: "smart-akdns",
          server: $dns_server,
          server_port: 53,
          detour: "PROXY"
        } else {
            type: "https",
            tag: "strict-doh",
            server: $dns_server,
            server_port: 443,
            path: "/dns-query",
            tls: {
              enabled: true,
              server_name: "cloudflare-dns.com",
              insecure: false
            },
            detour: "PROXY"
          } end)],
        final: (if $dns_mode == "akdns" then "smart-akdns" else "strict-doh" end),
        strategy: $dns_strategy
      },
      inbounds: [
        {
          type: "tun",
          tag: "tun-in",
          address: [
            "172.19.0.1/30",
            "fdfe:dcba:9876::1/126"
          ],
          auto_route: true,
          strict_route: true,
          stack: "mixed"
        }
      ],
      outbounds: ([
        {
          type: "selector",
          tag: "PROXY",
          outbounds: ([
            "HY2",
            "TUIC-v5",
            "SS2022",
            "AnyTLS",
            "Trojan-TLS",
            "VLESS-Reality-Vision"
          ] + (if $anyreality_enabled then ["AnyReality"] else [] end)),
          default: "HY2"
        },
        {
          type: "hysteria2",
          tag: "HY2",
          server: $server,
          server_ports: [$hy2_ports],
          hop_interval: "30s",
          password: $hy2_password,
          obfs: {
            type: "salamander",
            password: $hy2_obfs_password
          },
          tls: {
            enabled: true,
            server_name: $domain,
            insecure: false,
            alpn: ["h3"]
          }
        },
        {
          type: "tuic",
          tag: "TUIC-v5",
          server: $server,
          server_port: $tuic_port,
          uuid: $tuic_uuid,
          password: $tuic_password,
          congestion_control: "bbr",
          udp_relay_mode: "native",
          tls: {
            enabled: true,
            server_name: $domain,
            insecure: false,
            alpn: ["h3"]
          }
        },
        {
          type: "shadowsocks",
          tag: "SS2022",
          server: $server,
          server_port: $ss_port,
          method: "2022-blake3-aes-128-gcm",
          password: $ss_password
        },
        {
          type: "anytls",
          tag: "AnyTLS",
          server: $server,
          server_port: $anytls_port,
          password: $anytls_password,
          tls: {
            enabled: true,
            server_name: $domain,
            insecure: false,
            alpn: ["h2", "http/1.1"]
          }
        },
        {
          type: "trojan",
          tag: "Trojan-TLS",
          server: $server,
          server_port: $trojan_port,
          password: $trojan_password,
          tls: {
            enabled: true,
            server_name: $domain,
            insecure: false
          }
        },
        {
          type: "vless",
          tag: "VLESS-Reality-Vision",
          server: $server,
          server_port: $vision_port,
          uuid: $vision_uuid,
          flow: "xtls-rprx-vision",
          network: "tcp",
          tls: {
            enabled: true,
            server_name: $domain,
            insecure: false,
            utls: {
              enabled: true,
              fingerprint: "chrome"
            },
            reality: {
              enabled: true,
              public_key: $vision_public_key,
              short_id: $vision_short_id
            }
          }
        }
      ] + (if $anyreality_enabled then [{
        type: "anytls",
        tag: "AnyReality",
        server: $server,
        server_port: $anyreality_port,
        password: $anyreality_password,
        tls: {
          enabled: true,
          server_name: $domain,
          insecure: false,
          utls: {
            enabled: true,
            fingerprint: "chrome"
          },
          reality: {
            enabled: true,
            public_key: $anyreality_public_key,
            short_id: $anyreality_short_id
          }
        }
      }] else [] end)),
      route: {
        rules: [
          {
            protocol: "dns",
            action: "hijack-dns"
          },
          {
            ip_version: $rejected_ip_version,
            action: "reject"
          }
        ],
        final: "PROXY",
        auto_detect_interface: true
      },
      experimental: {
        cache_file: {
          enabled: true
        }
      }
    }' | write_atomic "$target"
}

render_proxy_nodes() {
  local server="$1" ip_version="$2" route_hy2_start="$3" route_hy2_end="$4"
  local route_tuic_port="$5" route_ss_port="$6" route_anytls_port="$7"
  local route_trojan_port="$8" route_vision_port="$9"
  cat <<EOF
  - name: "HY2"
    type: hysteria2
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_hy2_start}
    ports: "${route_hy2_start}-${route_hy2_end}"
    hop-interval: 30
    password: "${HY2_PASSWORD}"
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    skip-cert-verify: false
  - name: "TUIC-v5"
    type: tuic
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_tuic_port}
    uuid: "${TUIC_UUID}"
    password: "${TUIC_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    disable-sni: false
    reduce-rtt: false
    udp-relay-mode: native
    congestion-controller: bbr
    skip-cert-verify: false
  - name: "SS2022"
    type: ss
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_ss_port}
    cipher: "2022-blake3-aes-128-gcm"
    password: "${SS_PASSWORD}"
    udp: true
  - name: "AnyTLS"
    type: anytls
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_anytls_port}
    password: "${ANYTLS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h2, http/1.1]
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
  - name: "Trojan-TLS"
    type: trojan
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_trojan_port}
    password: "${TROJAN_PASSWORD}"
    sni: "${DOMAIN}"
    udp: true
    skip-cert-verify: false
  - name: "VLESS-Reality-Vision"
    type: vless
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_vision_port}
    uuid: "${VISION_UUID}"
    encryption: ""
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${VISION_PUBLIC_KEY}"
      short-id: "${VISION_SHORT_ID}"
    skip-cert-verify: false
EOF
}

render_xhttp_node() {
  local server="$1" ip_version="$2" route_xhttp_port="$3"
  cat <<EOF
  - name: "VLESS-Reality-XHTTP"
    type: vless
    server: "${server}"
    ip-version: ${ip_version}
    port: ${route_xhttp_port}
    uuid: "${XHTTP_UUID}"
    encryption: ""
    network: xhttp
    tls: true
    udp: true
    alpn: [h2]
    servername: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${XHTTP_PUBLIC_KEY}"
      short-id: "${XHTTP_SHORT_ID}"
    xhttp-opts:
      path: "${XHTTP_PATH}"
      host: "${DOMAIN}"
      mode: stream-one
    skip-cert-verify: false
EOF
}

render_stash_yaml() {
  local target="$1" server="$2" route_hy2_start="$3" route_hy2_end="$4"
  local route_tuic_port="$5" route_ss_port="$6" route_anytls_port="$7"
  local route_trojan_port="$8" route_vision_port="$9"
  local dns_mode="${10}" dns_server="${11}"
  {
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
EOF
  if [[ "$dns_mode" == akdns ]]; then
    cat <<EOF
dns:
  nameserver:
    - "tcp://${dns_server}"
  follow-rule: true
EOF
  fi
  cat <<EOF

proxies:
  - name: "HY2"
    type: hysteria2
    server: "${server}"
    port: ${route_hy2_start}
    ports: "${route_hy2_start}-${route_hy2_end}"
    hop-interval: 30
    auth: "${HY2_PASSWORD}"
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    skip-cert-verify: false
  - name: "TUIC-v5"
    type: tuic
    version: 5
    server: "${server}"
    port: ${route_tuic_port}
    uuid: "${TUIC_UUID}"
    password: "${TUIC_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    skip-cert-verify: false
  - name: "SS2022"
    type: ss
    server: "${server}"
    port: ${route_ss_port}
    cipher: "2022-blake3-aes-128-gcm"
    password: "${SS_PASSWORD}"
    udp: true
  - name: "AnyTLS"
    type: anytls
    server: "${server}"
    port: ${route_anytls_port}
    password: "${ANYTLS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h2, http/1.1]
    skip-cert-verify: false
  - name: "Trojan-TLS"
    type: trojan
    server: "${server}"
    port: ${route_trojan_port}
    password: "${TROJAN_PASSWORD}"
    sni: "${DOMAIN}"
    udp: true
    skip-cert-verify: false
  - name: "VLESS-Reality-Vision"
    type: vless
    server: "${server}"
    port: ${route_vision_port}
    uuid: "${VISION_UUID}"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    sni: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${VISION_PUBLIC_KEY}"
      short-id: "${VISION_SHORT_ID}"
    skip-cert-verify: false

proxy-groups:
  - name: "PROXY"
    type: select
    proxies: [HY2, TUIC-v5, SS2022, AnyTLS, Trojan-TLS, VLESS-Reality-Vision]

rules:
  - MATCH,PROXY
EOF
  } | write_atomic "$target"
}

render_client_yaml() {
  local target="$1" include_xhttp="$2" server="$3" ip_version="$4" names
  local route_hy2_start="$5" route_hy2_end="$6" route_tuic_port="$7"
  local route_ss_port="$8" route_anytls_port="$9" route_trojan_port="${10}"
  local route_vision_port="${11}" route_xhttp_port="${12}"
  local dns_mode="${13}" dns_server="${14}"
  if [[ "$include_xhttp" == "yes" ]]; then
    names='[HY2, TUIC-v5, SS2022, AnyTLS, Trojan-TLS, VLESS-Reality-Vision, VLESS-Reality-XHTTP]'
  else
    names='[HY2, TUIC-v5, SS2022, AnyTLS, Trojan-TLS, VLESS-Reality-Vision]'
  fi

  {
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
EOF
    if [[ "$dns_mode" == akdns ]]; then
      cat <<EOF
dns:
  enable: true
  ipv6: false
  enhanced-mode: redir-host
  respect-rules: true
  default-nameserver:
    - 1.1.1.1
  proxy-server-nameserver:
    - 1.1.1.1
  nameserver:
    - "tcp://${dns_server}#PROXY"
EOF
    fi
    cat <<EOF

proxies:
EOF
    render_proxy_nodes "$server" "$ip_version" \
      "$route_hy2_start" "$route_hy2_end" "$route_tuic_port" "$route_ss_port" \
      "$route_anytls_port" "$route_trojan_port" "$route_vision_port"
    [[ "$include_xhttp" == "yes" ]] \
      && render_xhttp_node "$server" "$ip_version" "$route_xhttp_port"
    cat <<EOF

proxy-groups:
  - name: "PROXY"
    type: select
    proxies: ${names}

rules:
  - MATCH,PROXY
EOF
  } | write_atomic "$target"
}

render_shadowrocket() {
  local target="$1" server="$2" route_hy2_start="$3" route_hy2_end="$4"
  local route_tuic_port="$5" route_ss_port="$6" route_anytls_port="$7"
  local route_trojan_port="$8" route_vision_port="$9" route_xhttp_port="${10}"
  local route_anyreality_port="${11:-}"
  local route_anyreality_enabled="${12:-false}"
  # The strict variants use an IP literal so Shadowrocket cannot resolve or
  # fall back to the other address family. TLS SNI, REALITY serverName and
  # XHTTP Host remain bound to the certificate domain.
  {
    cat <<EOF
proxies:
  - name: "HY2"
    type: hysteria2
    server: "${server}"
    port: ${route_hy2_start}
    ports: "${route_hy2_start}-${route_hy2_end}"
    port-range: "${route_hy2_start}-${route_hy2_end}"
    hop-interval: 30
    password: "${HY2_PASSWORD}"
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    skip-cert-verify: false
  - name: "TUIC-v5"
    type: tuic
    version: 5
    server: "${server}"
    port: ${route_tuic_port}
    uuid: "${TUIC_UUID}"
    password: "${TUIC_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h3]
    udp-relay-mode: native
    congestion-controller: bbr
    skip-cert-verify: false
  - name: "SS2022"
    type: ss
    server: "${server}"
    port: ${route_ss_port}
    cipher: "2022-blake3-aes-128-gcm"
    password: "${SS_PASSWORD}"
    udp: true
  - name: "AnyTLS"
    type: anytls
    server: "${server}"
    port: ${route_anytls_port}
    password: "${ANYTLS_PASSWORD}"
    sni: "${DOMAIN}"
    alpn: [h2, http/1.1]
    client-fingerprint: chrome
    skip-cert-verify: false
EOF
  if [[ "$route_anyreality_enabled" == "true" && -n "$route_anyreality_port" ]]; then
    cat <<EOF
  - name: "AnyReality"
    type: anytls
    server: "${server}"
    port: ${route_anyreality_port}
    password: "${ANYREALITY_PASSWORD}"
    sni: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${ANYREALITY_PUBLIC_KEY}"
      short-id: "${ANYREALITY_SHORT_ID}"
    skip-cert-verify: false
EOF
  fi
  cat <<EOF
  - name: "Trojan-TLS"
    type: trojan
    server: "${server}"
    port: ${route_trojan_port}
    password: "${TROJAN_PASSWORD}"
    sni: "${DOMAIN}"
    udp: true
    skip-cert-verify: false
  - name: "VLESS-Reality-Vision"
    type: vless
    server: "${server}"
    port: ${route_vision_port}
    uuid: "${VISION_UUID}"
    encryption: ""
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${VISION_PUBLIC_KEY}"
      short-id: "${VISION_SHORT_ID}"
    skip-cert-verify: false
  - name: "VLESS-Reality-XHTTP"
    type: vless
    server: "${server}"
    port: ${route_xhttp_port}
    uuid: "${XHTTP_UUID}"
    encryption: ""
    network: xhttp
    tls: true
    udp: true
    alpn: [h2]
    servername: "${DOMAIN}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${XHTTP_PUBLIC_KEY}"
      short-id: "${XHTTP_SHORT_ID}"
    xhttp-opts:
      path: "${XHTTP_PATH}"
      host: "${DOMAIN}"
      mode: stream-one
    skip-cert-verify: false
EOF
  } | write_atomic "$target"
}
