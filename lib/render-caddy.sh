#!/usr/bin/env bash

# Caddy subscription sites and HTTP/TLS entrypoint rendering. Loaded through
# lib/render.sh.

render_caddy_subscription_handlers() {
  local token="$1" family="$2" family_path="${3:-}"
  local url_prefix="/${token}"
  if [[ -n "$family_path" ]]; then
    url_prefix+="/${family_path}"
  fi
  cat <<EOF
	handle ${url_prefix}/mihomo.yaml {
		rewrite * /mihomo-${family}.yaml
		root * ${NEKO_SUB_DIR}
		header Content-Type "text/yaml; charset=utf-8"
		file_server
	}
	handle ${url_prefix}/stash.yaml {
		rewrite * /stash-${family}.yaml
		root * ${NEKO_SUB_DIR}
		header Content-Type "text/yaml; charset=utf-8"
		file_server
	}
	handle ${url_prefix}/shadowrocket.txt {
		rewrite * /shadowrocket-${family}.txt
		root * ${NEKO_SUB_DIR}
		header Content-Type "text/yaml; charset=utf-8"
		file_server
	}
	handle ${url_prefix}/sing-box.json {
		rewrite * /sing-box-${family}.json
		root * ${NEKO_SUB_DIR}
		header Content-Type "application/json; charset=utf-8"
		file_server
	}
EOF
}

render_caddy_subscription_site() {
  local domain="$1" token="$2" family="$3"
  cat <<EOF
https://${domain} {
	tls ${CERT_FILE} ${KEY_FILE}
	header {
		Cache-Control "no-store"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
	}
EOF
  render_caddy_subscription_handlers "$token" "$family"
  cat <<EOF
	handle {
		respond "Not Found" 404
	}
}

EOF
}

# DOMAIN and the other render globals come from the validated state contract.
# shellcheck disable=SC2153
render_caddy() {
  local http_hosts="http://${DOMAIN}"
  if network_mode_has_ipv4; then
    http_hosts+=", http://${SUBSCRIPTION_DOMAIN_IPV4}"
  fi
  if network_mode_has_ipv6; then
    http_hosts+=", http://${SUBSCRIPTION_DOMAIN_IPV6}"
  fi

  {
    cat <<EOF
{
	admin off
	auto_https off
	persist_config off
	servers {
		protocols h1 h2
	}
}

${http_hosts} {
	@acme path /.well-known/acme-challenge/*
	handle @acme {
		root * ${NEKO_VAR}/acme
		file_server
	}
	handle {
		redir https://{host}{uri} 308
	}
}

https://${DOMAIN} {
	tls ${CERT_FILE} ${KEY_FILE}
	header {
		Cache-Control "no-store"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
	}
EOF
    # The base hostname is the canonical subscription download endpoint.  In
    # dual-stack mode it can be reached over either family, while every node
    # inside the selected profile still uses an exact same-family IP literal.
    # Family-specific sites below remain available for existing installations.
    if network_mode_has_ipv4; then
      render_caddy_subscription_handlers "$SUB_TOKEN_IPV4" v4 v4
    fi
    if network_mode_has_ipv6; then
      render_caddy_subscription_handlers "$SUB_TOKEN_IPV6" v6 v6
    fi
    if network_mode_has_cross_routes; then
      render_caddy_subscription_handlers \
        "$SUB_TOKEN_IPV4_TO_IPV6" v4-to-v6 v4-to-v6
      render_caddy_subscription_handlers \
        "$SUB_TOKEN_IPV6_TO_IPV4" v6-to-v4 v6-to-v4
    fi
    cat <<EOF
	handle {
		respond "Welcome" 200
	}
}

https://${DOMAIN}:8443 {
	bind 127.0.0.1
	tls ${CERT_FILE} ${KEY_FILE}
	header {
		Cache-Control "no-store"
		X-Content-Type-Options "nosniff"
	}
	respond "Welcome" 200
}
EOF
    if network_mode_has_ipv4; then
      render_caddy_subscription_site \
        "$SUBSCRIPTION_DOMAIN_IPV4" "$SUB_TOKEN_IPV4" v4
    fi
    if network_mode_has_ipv6; then
      render_caddy_subscription_site \
        "$SUBSCRIPTION_DOMAIN_IPV6" "$SUB_TOKEN_IPV6" v6
    fi
  } | write_atomic "${NEKO_CONFIG_DIR}/Caddyfile"
}
