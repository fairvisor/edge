# VM Installation (Docker + systemd)

## 1) Create env file

Create `/etc/fairvisor/fairvisor.env`:

```bash
FAIRVISOR_MODE=decision_service
FAIRVISOR_CONFIG_FILE=/etc/fairvisor/policy.json
FAIRVISOR_SHARED_DICT_SIZE=128m
FAIRVISOR_LOG_LEVEL=info
```

For SaaS mode, replace config file settings with:

```bash
FAIRVISOR_SAAS_URL=https://api.fairvisor.com
FAIRVISOR_EDGE_ID=edge-prod-1
FAIRVISOR_EDGE_TOKEN=<token>
```

## 2) Add systemd unit

`/etc/systemd/system/fairvisor-edge.service`:

```ini
[Unit]
Description=Fairvisor Edge
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5
EnvironmentFile=/etc/fairvisor/fairvisor.env
ExecStartPre=-/usr/bin/docker rm -f fairvisor-edge
ExecStart=/usr/bin/docker run --name fairvisor-edge \
  --env-file /etc/fairvisor/fairvisor.env \
  -p 8080:8080 \
  -v /etc/fairvisor/policy.json:/etc/fairvisor/policy.json:ro \
  ghcr.io/fairvisor/fairvisor-edge:v0.1.0
ExecStop=/usr/bin/docker stop fairvisor-edge

[Install]
WantedBy=multi-user.target
```

## 3) Start service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fairvisor-edge
sudo systemctl status fairvisor-edge
```

## 4) Verify

```bash
curl -sf http://127.0.0.1:8080/livez
curl -sf http://127.0.0.1:8080/readyz
```
