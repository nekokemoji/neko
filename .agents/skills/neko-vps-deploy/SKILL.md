---
name: neko-vps-deploy
description: Deploy, inspect, or finish Neko on a user-authorized Linux VPS over SSH, wait for the operation to complete, validate the installed services and state, and return the exact four single-stack or eight dual-stack subscription URLs. Use when a user asks Codex or ChatGPT to install Neko on a VPS, continue a failed Neko deployment, retrieve Neko subscription links, or turn VPS access into a completed Neko setup. Covers safe SSH and secret handling, existing-install detection, strict IPv4/IPv6 DNS, Cloudflare DNS-01 or HTTP-01, bounded waiting, rollback-aware failure handling, and final subscription-link verification.
---

# Deploy Neko to a VPS

Complete the deployment rather than stopping after printing an install command. Treat success as all of the following:

- the installer or existing installation is valid;
- every required service and the renewal timer pass checks;
- a single-stack installation yields exactly four unique URLs;
- a dual-stack installation yields exactly eight unique URLs;
- the final reply returns every URL, grouped by address family and client.

If any condition is unverified, report the exact blocker and do not claim success.

## Preserve security boundaries

- Operate only on a server the user is authorized to administer.
- Never ask the user to paste an SSH password, private key, Cloudflare Token, one-time code, or subscription URL into ordinary chat.
- Use an already configured SSH key or a protected secret-input mechanism. If password-only SSH is the sole option and no protected input exists, stop and ask the user to configure a key.
- If a durable secret was pasted into chat, do not use it. Tell the user to rotate it and request a fresh value through a protected mechanism.
- Keep host-key checking enabled. Reuse a known key, or verify a new fingerprint through the provider console or another independent channel. `ssh-keyscan` alone does not authenticate a new host.
- Do not put a Cloudflare Token in an argument, environment dump, shell history, process list, log, repository, or workspace artifact. Transfer it as a mode-`0600` temporary file through the protected channel and remove the temporary copy after installation. The installer stores its renewal copy with root-only permissions.
- Treat full subscription URLs as credentials. Return them only to the requesting user in the current conversation; never post them to GitHub, logs, or third-party sites.
- Do not loosen Neko's strict IPv4/IPv6, certificate, firewall, rollback, or private-network protections to make a failing install appear successful.

## Resolve required inputs

Use the supplied SSH user and port exactly. Default the user to `root` and the port to `22` only when omitted.

Obtain or confirm:

- VPS host or IP and verified SSH host key;
- SSH authentication method;
- base domain, such as `node.example.com`;
- ACME email, defaulting to `admin@<base-domain>` only with the user's acceptance;
- network mode: `ipv4-only`, `ipv6-only`, or `dual`;
- ACME method: `cloudflare-dns-01` or `http-01`;
- a protected Cloudflare Token file when DNS-01 is selected.

Do not guess the domain, DNS ownership, network mode, or ACME method. Read-only VPS inspection may establish available routes and addresses, but the user must control the domain and authorize the selected certificate method. If the user supplied only VPS access, inspect first and ask only for the missing domain/DNS/ACME choices.

For current supported systems and install flags, read the repository's `README.md`, `install.sh`, and `versions.env` from `https://github.com/nekokemoji/neko` before deployment. Do not rely on a remembered release number.

## Establish the SSH session

Use a dedicated known-hosts file or the user's existing verified entry. Prefer key authentication, `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes`, `ConnectTimeout=15`, `ServerAliveInterval=30`, and `ServerAliveCountMax=3`.

After connecting, perform read-only checks:

- `/etc/os-release`, architecture, and PID 1;
- root access or non-interactive `sudo -n`;
- IPv4 and IPv6 default routes needed by the chosen mode;
- at least 768 MiB free under `/var/tmp`;
- current DNS records for the base, `v4.`, and `v6.` names;
- existing `/etc/neko/state.json`, Neko paths, users, and systemd units.

Require a supported distribution, `amd64` or `arm64`, and systemd. Do not call a container or user-mode environment a full VPS validation.

## Reuse a complete installation

If `/etc/neko/state.json` exists, do not reinstall. Validate the existing installation and collect its current URLs.

If Neko paths or units exist without a readable valid state file, stop. Report the partial-install evidence and inspect the previous failure. Never delete or overwrite it automatically.

## Validate DNS before ACME

Match Neko's strict DNS model:

- `ipv4-only`: the base and `v4.<base>` names resolve directly to the VPS IPv4; do not leave AAAA or CNAME records on the strict IPv4 name.
- `ipv6-only`: the base and `v6.<base>` names resolve directly to the VPS IPv6; do not leave A or CNAME records on the strict IPv6 name.
- `dual`: the base name has the VPS A and AAAA records, `v4.<base>` has only the matching A record, and `v6.<base>` has only the matching AAAA record.

All names must be DNS-only, not CDN/proxied. Do not modify DNS or cloud security groups unless the user separately authorizes that external action.

## Run the stable installer

Use the stable `main/bootstrap.sh` entrypoint, which downloads a pinned source revision. Pass explicit non-interactive arguments rather than automating terminal prompts:

```text
--domain <base-domain>
--email <acme-email>
--network-mode <ipv4-only|ipv6-only|dual>
--acme-method <cloudflare-dns-01|http-01>
--yes
```

For DNS-01, also pass `--cloudflare-token-file <root-readable-temporary-file>`. For HTTP-01, do not supply any Token.

Keep the SSH command attached until it exits. Use the execution surface's long-running session and poll it without restarting the installer. Send short progress updates during long downloads or certificate work so the user is not left without an update for more than about one minute.

Allow up to 30 minutes for the overall operation while respecting Neko's own bounded ACME timeout. If SSH drops, reconnect and inspect the state, lock, services, and rollback result before deciding whether any retry is safe.

## Handle failures without amplification

- Preserve the original installer output and exit code, but redact secrets and full URLs from diagnostic summaries.
- On Cloudflare `9109: Invalid access token`, stop using that Token. Explain the required `Zone / Zone / Read`, `Zone / DNS / Edit`, and correct Zone Resources scope.
- On ACME `429` or `rateLimited`, do not keep reinstalling. Report the displayed retry time.
- On timeout or DNS failure, fix the underlying reachability or records before one deliberate retry.
- Confirm that a first-install failure rolled back its created state. On an existing installation or renewal failure, preserve the old certificate and configuration.
- Never use uninstall, broad deletion, firewall relaxation, or a different address family as an implicit recovery step.

## Verify and collect the links

After a successful installer exit—or for an existing installation—run a root shell that:

1. checks each of `neko-caddy`, `neko-sing-box`, `neko-xray`, and `neko-hysteria` with `systemctl is-active`;
2. checks that `neko-renew.timer` is enabled and active;
3. sources `/usr/local/libexec/neko/lib/common.sh`;
4. calls `show_subscription_links` directly, without opening the interactive QR menu.

Parse only lines beginning with `https://`. Require unique URLs and validate their shape:

```text
https://<base-domain>/<token>/<v4|v6>/<mihomo.yaml|stash.yaml|shadowrocket.txt|sing-box.json>
```

Compare the count with `/etc/neko/state.json`:

- `ipv4-only`: four IPv4 URLs;
- `ipv6-only`: four IPv6 URLs;
- `dual`: four IPv4 and four IPv6 URLs.

When network access permits, fetch every URL with a short timeout without printing its body or placing the literal URL in a logged command. A failed external probe is a verification limitation to report; it is not permission to reveal state or weaken TLS.

Also retain the installer's exact required TCP/UDP port list for the user. Explain that local UFW/firewalld rules cannot replace cloud-provider security-group changes.

## Return the result

Lead with the outcome. Include:

- detected OS, architecture, Neko release, and network mode;
- service and renewal-timer result;
- all four or eight full subscription URLs grouped under IPv4/IPv6 and labeled Mihomo, Stash, Shadowrocket, and sing-box;
- required cloud security-group ports or any remaining external verification limit;
- a short warning that the URLs are credentials and should not be shared publicly.

If blocked, return no invented or partial links. State the last completed checkpoint, the precise error, whether rollback or the previous installation was preserved, and the single safest next action.
