# Reference Points


## Gm
SIP between PGW/UPF (technically UE) and P-CSCF


## Mw
SIP between CSCFs


## Cx
Diameter between I-CSCF/S-CSCF and HSS
- User-Authorization-Request/Answer (from I-CSCF)
- Multimedia-Auth-Request/Answer (from S-CSCF)
- Server-Assignment-Request/Answer (from S-CSCF)
- Location-Info-Request/Answer (from I-CSCF)
- Registration-Termination-Request/Answer (from S-CSCF)
- Push-Profile-Request/Answer (from HSS to S-CSCF)

### Serving CSCF
Serving CSCF can verify received data on Cx interface. This is done by the forwarding module for ISC interface.

The validation data could be downloaded from https://www.etsi.org/deliver/etsi_ts/129200_129299/129228/18.00.00_60/ts_129228v180000p0.zip

### Dx Reference Point
In case of multiple HSS instances, to be able to determine which HSS should be used,
the request could be sent first to SLF (Subscription Locator Function). The SLF
will reply with Diameter Redirect and the request should be sent over Cx to the
particular HSS. This mechanism could be replaced by DRA (Diameter Routing Agent).
The Cx message could be sent to the DRA and the DRA will route it to the correct HSS.


## Rx
Diameter between P-CSCF and PCRF
- AA-Request/Answer
- Session-Termination-Request/Answer


## ISC (IMS Service Control)
SIP between S-CSCF and AS (Application Server). Example AS SMSC


## Ro/Rf
Diameter between S-CSCF and OCS
