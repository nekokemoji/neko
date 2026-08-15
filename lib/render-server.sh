#!/usr/bin/env bash

# Server-side sing-box, Xray, and Hysteria configuration rendering. Loaded
# through lib/render.sh.

write_atomic() {
  local target="$1" mode="${2:-0640}" tmp
  mkdir -p "$(dirname -- "$target")"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  chown "root:${NEKO_USER}" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$target"
}

# DOMAIN and the other render globals are populated by load_state.
# shellcheck disable=SC2153
render_sing_box() {
  jq -n \
    --arg domain "$DOMAIN" \
    --arg mode "$NETWORK_MODE" \
    --arg listen_v4 "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg listen_v6 "$SUBSCRIPTION_IPV6_ADDRESS" \
    --arg strict_dns_v6 "$NEKO_STRICT_IPV6_DNS_ADDRESS" \
    --arg strict_dns_tls_name "$NEKO_STRICT_DNS_TLS_NAME" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    --argjson tuic_port "$TUIC_PORT" \
    --arg tuic_uuid "$TUIC_UUID" \
    --arg tuic_password "$TUIC_PASSWORD" \
    --argjson ss_port "$SS_PORT" \
    --arg ss_password "$SS_PASSWORD" \
    --argjson anytls_port "$ANYTLS_PORT" \
    --arg anytls_password "$ANYTLS_PASSWORD" \
    --argjson anyreality_enabled "$ANYREALITY_ENABLED" \
    --argjson anyreality_port "${ANYREALITY_PORT:-null}" \
    --arg anyreality_password "$ANYREALITY_PASSWORD" \
    --arg anyreality_private_key "$ANYREALITY_PRIVATE_KEY" \
    --arg anyreality_short_id "$ANYREALITY_SHORT_ID" \
    --argjson trojan_port "$TROJAN_PORT" \
    --arg trojan_password "$TROJAN_PASSWORD" \
    --argjson cross_tuic_port "${CROSS_TUIC_PORT:-null}" \
    --argjson cross_ss_port "${CROSS_SS_PORT:-null}" \
    --argjson cross_anytls_port "${CROSS_ANYTLS_PORT:-null}" \
    --argjson cross_anyreality_port "${CROSS_ANYREALITY_PORT:-null}" \
    --argjson cross_trojan_port "${CROSS_TROJAN_PORT:-null}" \
    'def family_inbounds(
      $suffix; $listen; $route_tuic_port; $route_ss_port;
      $route_anytls_port; $route_trojan_port; $route_anyreality_port
    ): ([
        {
          type: "tuic",
          tag: ("tuic-" + $suffix + "-in"),
          listen: $listen,
          listen_port: $route_tuic_port,
          users: [{uuid: $tuic_uuid, password: $tuic_password}],
          congestion_control: "bbr",
          zero_rtt_handshake: false,
          tls: {
            enabled: true,
            server_name: $domain,
            alpn: ["h3"],
            certificate_path: $cert,
            key_path: $key
          }
        },
        {
          type: "shadowsocks",
          tag: ("ss2022-" + $suffix + "-in"),
          listen: $listen,
          listen_port: $route_ss_port,
          method: "2022-blake3-aes-128-gcm",
          password: $ss_password
        },
        {
          type: "anytls",
          tag: ("anytls-" + $suffix + "-in"),
          listen: $listen,
          listen_port: $route_anytls_port,
          users: [{password: $anytls_password}],
          tls: {
            enabled: true,
            server_name: $domain,
            alpn: ["h2", "http/1.1"],
            certificate_path: $cert,
            key_path: $key
          }
        },
        {
          type: "trojan",
          tag: ("trojan-" + $suffix + "-in"),
          listen: $listen,
          listen_port: $route_trojan_port,
          users: [{password: $trojan_password}],
          tls: {
            enabled: true,
            server_name: $domain,
            certificate_path: $cert,
            key_path: $key
          }
        }
      ] + (if $anyreality_enabled then [{
        type: "anytls",
        tag: ("anyreality-" + $suffix + "-in"),
        listen: $listen,
        listen_port: $route_anyreality_port,
        users: [{password: $anyreality_password}],
        tls: {
          enabled: true,
          server_name: $domain,
          reality: {
            enabled: true,
            handshake: {server: "127.0.0.1", server_port: 8443},
            private_key: $anyreality_private_key,
            short_id: [$anyreality_short_id]
          }
        }
      }] else [] end));
    def has_v4: ($mode == "ipv4-only" or $mode == "dual");
    def has_v6: ($mode == "ipv6-only" or $mode == "dual");
    def has_cross: ($mode == "dual");
    def same_v4_inbound_tags: [
      "tuic-v4-in", "ss2022-v4-in", "anytls-v4-in", "trojan-v4-in"
    ] + (if $anyreality_enabled then ["anyreality-v4-in"] else [] end);
    def same_v6_inbound_tags: [
      "tuic-v6-in", "ss2022-v6-in", "anytls-v6-in", "trojan-v6-in"
    ] + (if $anyreality_enabled then ["anyreality-v6-in"] else [] end);
    def cross_v4_to_v6_inbound_tags: [
      "tuic-v4-to-v6-in", "ss2022-v4-to-v6-in",
      "anytls-v4-to-v6-in", "trojan-v4-to-v6-in"
    ] + (if $anyreality_enabled then ["anyreality-v4-to-v6-in"] else [] end);
    def cross_v6_to_v4_inbound_tags: [
      "tuic-v6-to-v4-in", "ss2022-v6-to-v4-in",
      "anytls-v6-to-v4-in", "trojan-v6-to-v4-in"
    ] + (if $anyreality_enabled then ["anyreality-v6-to-v4-in"] else [] end);
    def v4_egress_inbound_tags:
      same_v4_inbound_tags
      + (if has_cross then cross_v6_to_v4_inbound_tags else [] end);
    def v6_egress_inbound_tags:
      same_v6_inbound_tags
      + (if has_cross then cross_v4_to_v6_inbound_tags else [] end);
    {
      log: {level: "info", timestamp: true},
      dns: {
        servers:
          ([{type: "local", tag: "local", prefer_go: true}]
          + (if has_v6 then [{
            type: "https",
            tag: "strict-v6",
            server: $strict_dns_v6,
            server_port: 443,
            path: "/dns-query",
            tls: {
              enabled: true,
              server_name: $strict_dns_tls_name,
              insecure: false
            }
          }] else [] end))
      },
      inbounds:
        ((if has_v4 then family_inbounds(
          "v4"; $listen_v4; $tuic_port; $ss_port; $anytls_port; $trojan_port;
          $anyreality_port
        ) else [] end)
        + (if has_v6 then family_inbounds(
          "v6"; $listen_v6; $tuic_port; $ss_port; $anytls_port; $trojan_port;
          $anyreality_port
        ) else [] end)
        + (if has_cross then family_inbounds(
          "v4-to-v6"; $listen_v4; $cross_tuic_port; $cross_ss_port;
          $cross_anytls_port; $cross_trojan_port; $cross_anyreality_port
        ) else [] end)
        + (if has_cross then family_inbounds(
          "v6-to-v4"; $listen_v6; $cross_tuic_port; $cross_ss_port;
          $cross_anytls_port; $cross_trojan_port; $cross_anyreality_port
        ) else [] end)),
      outbounds:
        ((if has_v4 then [{
          type: "direct",
          tag: "direct-v4",
          inet4_bind_address: $listen_v4,
          domain_resolver: {server: "local", strategy: "ipv4_only"}
        }] else [] end)
        + (if has_v6 then [{
          type: "direct",
          tag: "direct-v6",
          inet6_bind_address: $listen_v6,
          domain_resolver: {server: "strict-v6", strategy: "ipv6_only"}
        }] else [] end)),
      route: {
        rules:
          ([{
            port: [80, 443],
            action: "sniff",
            sniffer: ["http", "tls", "quic"],
            timeout: "1s"
          },
          {network: "tcp", port: 25, action: "reject"}]
          + (if has_v4 then [{
            inbound: v4_egress_inbound_tags,
            action: "resolve",
            server: "local",
            strategy: "ipv4_only"
          }] else [] end)
          + (if has_v6 then [{
            inbound: v6_egress_inbound_tags,
            action: "resolve",
            server: "strict-v6",
            strategy: "ipv6_only"
          }] else [] end)
          + [{ip_is_private: true, action: "reject"}]
          + (if has_v4 then [{
            inbound: v4_egress_inbound_tags,
            ip_version: 6,
            action: "reject"
          }] else [] end)
          + (if has_v6 then [{
            inbound: v6_egress_inbound_tags,
            ip_version: 4,
            action: "reject"
          }] else [] end)
          + (if has_v4 then [{
            inbound: v4_egress_inbound_tags,
            action: "route",
            outbound: "direct-v4"
          }] else [] end)
          + (if has_v6 then [{
            inbound: v6_egress_inbound_tags,
            action: "route",
            outbound: "direct-v6"
          }] else [] end)),
        final: (if has_v4 then "direct-v4" else "direct-v6" end)
      }
    }' | write_atomic "${NEKO_CONFIG_DIR}/sing-box.json"
}

render_xray() {
  jq -n \
    --arg domain "$DOMAIN" \
    --arg mode "$NETWORK_MODE" \
    --arg listen_v4 "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg listen_v6 "$SUBSCRIPTION_IPV6_ADDRESS" \
    --arg strict_dns_v6 "$NEKO_STRICT_IPV6_DNS_ADDRESS" \
    --argjson vision_port "$VISION_PORT" \
    --arg vision_uuid "$VISION_UUID" \
    --arg vision_private "$VISION_PRIVATE_KEY" \
    --arg vision_sid "$VISION_SHORT_ID" \
    --argjson xhttp_port "$XHTTP_PORT" \
    --arg xhttp_uuid "$XHTTP_UUID" \
    --arg xhttp_private "$XHTTP_PRIVATE_KEY" \
    --arg xhttp_sid "$XHTTP_SHORT_ID" \
    --arg xhttp_path "$XHTTP_PATH" \
    --argjson cross_vision_port "${CROSS_VISION_PORT:-null}" \
    --argjson cross_xhttp_port "${CROSS_XHTTP_PORT:-null}" \
    'def vision_inbound($suffix; $listen; $route_vision_port): {
        tag: ("vless-reality-vision-" + $suffix + "-in"),
        listen: $listen,
        port: $route_vision_port,
        protocol: "vless",
        settings: {
          clients: [{id: $vision_uuid, flow: "xtls-rprx-vision"}],
          decryption: "none"
        },
        streamSettings: {
          network: "raw",
          security: "reality",
          realitySettings: {
            show: false,
            target: "127.0.0.1:8443",
            xver: 0,
            serverNames: [$domain],
            privateKey: $vision_private,
            shortIds: [$vision_sid]
          }
        },
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls", "quic"],
          routeOnly: false
        }
      };
    def xhttp_inbound($suffix; $listen; $route_xhttp_port): {
        tag: ("vless-reality-xhttp-" + $suffix + "-in"),
        listen: $listen,
        port: $route_xhttp_port,
        protocol: "vless",
        settings: {
          clients: [{id: $xhttp_uuid}],
          decryption: "none"
        },
        streamSettings: {
          network: "xhttp",
          security: "reality",
          realitySettings: {
            show: false,
            target: "127.0.0.1:8443",
            xver: 0,
            serverNames: [$domain],
            privateKey: $xhttp_private,
            shortIds: [$xhttp_sid]
          },
          xhttpSettings: {
            path: $xhttp_path,
            mode: "auto"
          }
        },
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls", "quic"],
          routeOnly: false
        }
      };
    def has_v4: ($mode == "ipv4-only" or $mode == "dual");
    def has_v6: ($mode == "ipv6-only" or $mode == "dual");
    def has_cross: ($mode == "dual");
    {
      log: {loglevel: "warning"},
      dns: {
        queryStrategy: "UseIP",
        servers:
          ((if has_v4 then [{
            address: "localhost",
            queryStrategy: "UseIPv4"
          }] else [] end)
          + (if has_v6 then [{
            address: ("https+local://[" + $strict_dns_v6 + "]/dns-query"),
            queryStrategy: "UseIPv6"
          }] else [] end))
      },
      inbounds:
        ((if has_v4 then [
          vision_inbound("v4"; $listen_v4; $vision_port),
          xhttp_inbound("v4"; $listen_v4; $xhttp_port)
        ] else [] end)
        + (if has_v6 then [
          vision_inbound("v6"; $listen_v6; $vision_port),
          xhttp_inbound("v6"; $listen_v6; $xhttp_port)
        ] else [] end)
        + (if has_cross then [
          vision_inbound("v4-to-v6"; $listen_v4; $cross_vision_port),
          xhttp_inbound("v4-to-v6"; $listen_v4; $cross_xhttp_port),
          vision_inbound("v6-to-v4"; $listen_v6; $cross_vision_port),
          xhttp_inbound("v6-to-v4"; $listen_v6; $cross_xhttp_port)
        ] else [] end)),
      outbounds:
        ((if has_v4 then [{
          sendThrough: $listen_v4,
          protocol: "freedom",
          tag: "direct-v4",
          targetStrategy: "ForceIPv4",
          settings: {domainStrategy: "ForceIPv4"}
        }] else [] end)
        + (if has_v6 then [{
          sendThrough: $listen_v6,
          protocol: "freedom",
          tag: "direct-v6",
          targetStrategy: "ForceIPv6",
          settings: {domainStrategy: "ForceIPv6"}
        }] else [] end)
        + [{protocol: "blackhole", tag: "blocked"}]),
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: (
          [{
            type: "field",
            ip: [
              "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
              "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
              "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15",
              "224.0.0.0/4", "240.0.0.0/4",
              "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
            ],
            outboundTag: "blocked"
          },
          {
            type: "field",
            network: "tcp",
            port: 25,
            outboundTag: "blocked"
          }]
          + (if has_v4 then [{
            type: "field",
            inboundTag: ([
              "vless-reality-vision-v4-in", "vless-reality-xhttp-v4-in"
            ] + (if has_cross then [
              "vless-reality-vision-v6-to-v4-in",
              "vless-reality-xhttp-v6-to-v4-in"
            ] else [] end)),
            outboundTag: "direct-v4"
          }] else [] end)
          + (if has_v6 then [{
            type: "field",
            inboundTag: ([
              "vless-reality-vision-v6-in", "vless-reality-xhttp-v6-in"
            ] + (if has_cross then [
              "vless-reality-vision-v4-to-v6-in",
              "vless-reality-xhttp-v4-to-v6-in"
            ] else [] end)),
            outboundTag: "direct-v6"
          }] else [] end))
      }
    }' | write_atomic "${NEKO_CONFIG_DIR}/xray.json"
}

render_hysteria_family() {
  local target="$1" listen="$2" mode="$3" bind_field="$4" bind_address="$5"
  local resolver_block=""
  if [[ "$mode" == 6 ]]; then
    resolver_block="
resolver:
  type: https
  https:
    addr: \"[${NEKO_STRICT_IPV6_DNS_ADDRESS}]:443\"
    timeout: 10s
    sni: ${NEKO_STRICT_DNS_TLS_NAME}
    insecure: false
"
  fi
  write_atomic "$target" <<EOF
listen: "${listen}"

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: "${HY2_PASSWORD}"

obfs:
  type: salamander
  salamander:
    password: "${HY2_OBFS_PASSWORD}"
${resolver_block}
sniff:
  enable: true
  timeout: 1s
  rewriteDomain: false
  tcpPorts: "80,443"
  udpPorts: "443"

masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}/
    rewriteHost: true

outbounds:
  - name: direct
    type: direct
    direct:
      mode: ${mode}
      ${bind_field}: ${bind_address}

acl:
  inline:
    - reject(0.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(100.64.0.0/10)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(172.16.0.0/12)
    - reject(192.0.0.0/24)
    - reject(192.168.0.0/16)
    - reject(198.18.0.0/15)
    - reject(224.0.0.0/4)
    - reject(240.0.0.0/4)
    - reject(::/128)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)
    - reject(ff00::/8)
    - reject(all, tcp/25)
    - direct(all)
EOF
}

render_hysteria() {
  rm -f -- \
    "${NEKO_CONFIG_DIR}/hysteria-v4.yaml" \
    "${NEKO_CONFIG_DIR}/hysteria-v6.yaml" \
    "${NEKO_CONFIG_DIR}/hysteria-v4-to-v6.yaml" \
    "${NEKO_CONFIG_DIR}/hysteria-v6-to-v4.yaml" \
    "${NEKO_CONFIG_DIR}/hysteria.yaml"
  if network_mode_has_ipv4; then
    render_hysteria_family \
      "${NEKO_CONFIG_DIR}/hysteria-v4.yaml" \
      "${SUBSCRIPTION_IPV4_ADDRESS}:${HY2_START}-${HY2_END}" \
      4 bindIPv4 "$SUBSCRIPTION_IPV4_ADDRESS"
  fi
  if network_mode_has_ipv6; then
    render_hysteria_family \
      "${NEKO_CONFIG_DIR}/hysteria-v6.yaml" \
      "[${SUBSCRIPTION_IPV6_ADDRESS}]:${HY2_START}-${HY2_END}" \
      6 bindIPv6 "$SUBSCRIPTION_IPV6_ADDRESS"
  fi
  if network_mode_has_cross_routes; then
    render_hysteria_family \
      "${NEKO_CONFIG_DIR}/hysteria-v4-to-v6.yaml" \
      "${SUBSCRIPTION_IPV4_ADDRESS}:${CROSS_HY2_START}-${CROSS_HY2_END}" \
      6 bindIPv6 "$SUBSCRIPTION_IPV6_ADDRESS"
    render_hysteria_family \
      "${NEKO_CONFIG_DIR}/hysteria-v6-to-v4.yaml" \
      "[${SUBSCRIPTION_IPV6_ADDRESS}]:${CROSS_HY2_START}-${CROSS_HY2_END}" \
      4 bindIPv4 "$SUBSCRIPTION_IPV4_ADDRESS"
  fi
}
