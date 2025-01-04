# IMS
IP Multimedia Subsystem

Why another setup:
- use modern compose features (like interpolation) for simplicity
- go into a bit more depth of the Kamailio configuration for better understanding
- provide entirely software based playground for testing


## Specifications
- SIP [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261.html)
- SDP [RFC 2327](https://www.rfc-editor.org/rfc/rfc2327.html)
- RTP [RFC 1889](https://www.rfc-editor.org/rfc/rfc1889.html)
- IMS
  - [TS 23.228](https://www.etsi.org/deliver/etsi_ts/123200_123299/123228/18.07.00_60/ts_123228v180700p.pdf)
  - [TS 24.229](https://www.etsi.org/deliver/etsi_ts/124200_124299/124229/18.06.00_60/ts_124229v180600p.pdf)
- Diameter Cx [TS 29.229](https://www.etsi.org/deliver/etsi_ts/129200_129299/129229/18.01.00_60/ts_129229v180100p.pdf)
- Diameter Rx [TS 29.214](https://www.etsi.org/deliver/etsi_ts/129200_129299/129214/18.03.00_60/ts_129214v180300p.pdf)
- Diameter Ro/Rf
  - [RFC 8506](https://www.rfc-editor.org/rfc/rfc8506.html)
  - [TS 32.299](https://www.etsi.org/deliver/etsi_ts/132200_132299/132299/18.00.00_60/ts_132299v180000p.pdf)
- SMS [TS 24.341](https://www.etsi.org/deliver/etsi_ts/124300_124399/124341/18.00.00_60/ts_124341v180000p.pdf)
- Emergency [TS 23.167](https://www.etsi.org/deliver/etsi_ts/123100_123199/123167/18.02.00_60/ts_123167v180200p.pdf)


## Transactions
- [registration](doc/registration.md)
- [invite](doc/invite.md)


## Components
- IMS (compose.yml)
  - [x] [CSCF](doc/images.md#kamailio-p-cscfi-cscfs-cscf)
    - [x] Proxy
    - [x] Interrogating
    - [x] Serving
  - [x] MariaDB
  - [x] [rtpengine](doc/images.md#rtpengine)
  - [x] DNS
- Core Network (core.yml)
  - [ ] DRA
  - [x] [HSS](doc/images.md#open5gs-hsspcrfpgw)
  - [x] HSS UI
  - [ ] PCRF
  - [ ] PGW
  - [ ] SMSC
  - [x] MongoDB
- Billing (billing.yml)
  - [x] [OCS](doc/images.md#cgrates-billing)
- Monitoring (monitor.yml)
  - [x] Promtail
  - [x] Loki
  - [x] cAdvisor
  - [x] Prometheus
  - [ ] Alertmanager
  - [x] Grafana
- Testing (compose.yml)
  - [x] Doubango
