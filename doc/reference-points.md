# Reference Points


## Gm
SIP between PGW/UPF (technically UE) and P-CSCF


## Mw
SIP between CSCFs


## Cx
Diameter between I-CSCF/S-CSCF and HSS
- 300 User-Authorization-Request/Answer (from I-CSCF to HSS)
- 303 Multimedia-Auth-Request/Answer (from S-CSCF to HSS)
- 301 Server-Assignment-Request/Answer (from S-CSCF to HSS)
- 302 Location-Info-Request/Answer (from I-CSCF to HSS)
- 304 Registration-Termination-Request/Answer (from HSS to S-CSCF)
- 305 Push-Profile-Request/Answer (from HSS to S-CSCF)

### Serving CSCF
Serving CSCF can verify received data on Cx interface. This is done by the forwarding module for ISC interface.

The validation data could be downloaded from https://www.etsi.org/deliver/etsi_ts/129200_129299/129228/18.00.00_60/ts_129228v180000p0.zip

### Dx Reference Point
In case of multiple HSS instances, to be able to determine which HSS should be used,
the request could be sent first to SLF (Subscription Locator Function). The SLF
will reply with Diameter Redirect and the request should be sent over Cx to the
particular HSS. This mechanism could be replaced by DRA (Diameter Routing Agent).
The Cx message could be sent to the DRA and the DRA will route it to the correct HSS.

TS 23.228 5.8.1 User identity to HSS resolution
This clause describes the resolution mechanism, which enables the I-CSCF, the S-CSCF and the AS to find the address
of the HSS, that holds the subscriber data for a given user identity when multiple and separately addressable HSSs have
been deployed by the network operator. This resolution mechanism is implemented using a Subscription Locator
Function (SLF) or a Diameter Proxy Agent that proxies the request to the HSS. This resolution mechanism is not
required in networks that utilise a single HSS e.g. optionally, it could be switched off on the I-CSCF and on the S-CSCF
and/or on the AS using O&M mechanisms. An example for a single HSS solution is a server farm architecture. By
default, the resolution mechanism shall be supported.


## Rx/N5
Diameter/HTTP2 between P-CSCF and PCRF/PCR
| Rx (Diameter)                              | N5 (Npcf PolicyAuthorization)                                 | Initiator |
|--------------------------------------------|---------------------------------------------------------------|-----------|
| **265** AA-Request/Answer                  | **POST**   /app-sessions                                      | P-CSCF    |
| **265** AA-Request/Answer                  | **PATCH**  /app-sessions/_{appSessionId}_                     | P-CSCF    |
|                                            | **PUT**    /app-sessions/_{appSessionId}_/events-subscription | P-CSCF    |
|                                            | **DELETE** /app-sessions/_{appSessionId}_/events-subscription | P-CSCF    |
| **275** Session-Termination-Request/Answer | **POST**   /app-sessions/_{appSessionId}_/delete              | P-CSCF    |
| **285** Re-Auth-RequestAnswer              | **POST**   /_{notifUri}_/notify                               | PCRF/PCF  |
| **274** Abort-Session-Request/Answer       | **POST**   /_{notifUri}_/terminate                            | PCRF/PCF  |


## ISC (IMS Service Control)
SIP between S-CSCF and AS (Application Server). Example AS SMSC


## Ro/Rf
Diameter between S-CSCF and OCS
- 272 Credit-Control-Request/Answer
