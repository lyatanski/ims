```mermaid
---
title: Session Control
---
sequenceDiagram
    UE1->>P-CSCF: SIP - INVITE
    P-CSCF->>UE1: SIP 100 - Trying
    P-CSCF->>S-CSCF: SIP - INVITE
    S-CSCF->>P-CSCF: SIP 100 - Trying
    opt Request-URI is a number (tel URI, or sip;user=phone)
        Note over S-CSCF: TS 24.229 5.4.3.2<br>A tel URI carries a number and no host, so nothing can route it as it stands.<br>A number dialled in a local form -- behind an international prefix (00...) or a<br>national trunk prefix -- is first normalised into +E.164 against the served user's<br>dial plan; one in neither form is left exactly as dialled, which is what a short<br>code needs. The S-CSCF then translates it into a SIP URI by ENUM (RFC 6116):<br>the digits are reversed into a name under the operator's ENUM tree, and the<br>NAPTR found there carries the regexp that rewrites the number into the URI.<br>The tree answers only for the ranges this network serves, so a miss means the<br>number is not an IMS number: it leaves through the trunk (the BGCF role,<br>TS 23.228 4.3.4) if one is configured, and is answered 404 if not.
        S-CSCF->>DNS: DNS - NAPTR 1.0.0.0.0.0.0.0.9.5.3.e164.mnc01.mcc001.3gppnetwork.org
        DNS->>S-CSCF: DNS - NAPTR E2U+sip, rewriting +359000000001 into sip:359000000001@ims.mnc01.mcc001.3gppnetwork.org
    end
    S-CSCF->>OCS: Diameter - initial orig Credit-Control-Request (CCR)
    OCS->>S-CSCF: Diameter - initial orig Credit-Control-Answer (CCA)
    Note over S-CSCF: TS 23.228 5.5.2<br>The Serving-CSCF handling session origination performs an analysis of the destination address<br>and forwards the request to the Interrogating-CSCF for the terminating user.<br>It could be local I-CSCF, if a subscriber of the same operator, or<br>I-CSCF entry point of other operator.
    S-CSCF->>I-CSCF: SIP - INVITE
    I-CSCF->>S-CSCF: SIP 100 - Trying
    I-CSCF->>HSS: Diameter - Location-Info-Request (LIR)
    HSS->>I-CSCF: Diameter - Location-Info-Answer (LIA)
    I-CSCF->>S-CSCF: SIP - INVITE
    S-CSCF->>I-CSCF: SIP 100 - Trying
    S-CSCF->>OCS: Diameter - initial term Credit-Control-Request (CCR)
    OCS->>S-CSCF: Diameter - initial term Credit-Control-Answer (CCA)
    S-CSCF->>P-CSCF: SIP - INVITE
    P-CSCF->>S-CSCF: SIP 100 - Trying
    P-CSCF->>UE2: SIP - INVITE
    alt
        UE1->>P-CSCF: SIP - CANCEL
        P-CSCF->>S-CSCF: SIP - CANCEL
        S-CSCF->>I-CSCF: SIP - CANCEL
        I-CSCF->>S-CSCF: SIP - CANCEL
        S-CSCF->>P-CSCF: SIP - CANCEL
        P-CSCF->>UE2: SIP - CANCEL
    else
        opt precondition
            UE2->>P-CSCF: SIP 183 - Session Progress
            P-CSCF->>S-CSCF: SIP 183 - Session Progress
            S-CSCF->>I-CSCF: SIP 183 - Session Progress
            I-CSCF->>S-CSCF: SIP 183 - Session Progress
            S-CSCF->>P-CSCF: SIP 183 - Session Progress
            P-CSCF->>UE1: SIP 183 - Session Progress
            opt 100rel
                UE1->>P-CSCF: SIP - PRACK
                P-CSCF->>S-CSCF: SIP - PRACK
                S-CSCF->>I-CSCF: SIP - PRACK
                I-CSCF->>S-CSCF: SIP - PRACK
                S-CSCF->>P-CSCF: SIP - PRACK
                P-CSCF->>UE2: SIP - PRACK
                UE2->>P-CSCF: SIP 200 - OK (PRACK)
                P-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
                S-CSCF->>I-CSCF: SIP 200 - OK (PRACK)
                I-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
                S-CSCF->>P-CSCF: SIP 200 - OK (PRACK)
                P-CSCF->>UE1: SIP 200 - OK (PRACK)
            end
        end

        UE2->>P-CSCF: SIP 180 - Ringing
        P-CSCF->>S-CSCF: SIP 180 - Ringing
        S-CSCF->>I-CSCF: SIP 180 - Ringing
        I-CSCF->>S-CSCF: SIP 180 - Ringing
        S-CSCF->>P-CSCF: SIP 180 - Ringing
        P-CSCF->>UE1: SIP 180 - Ringing
        opt 100rel
            UE1->>P-CSCF: SIP - PRACK
            P-CSCF->>S-CSCF: SIP - PRACK
            S-CSCF->>I-CSCF: SIP - PRACK
            I-CSCF->>S-CSCF: SIP - PRACK
            S-CSCF->>P-CSCF: SIP - PRACK
            P-CSCF->>UE2: SIP - PRACK
            UE2->>P-CSCF: SIP 200 - OK (PRACK)
            P-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
            S-CSCF->>I-CSCF: SIP 200 - OK (PRACK)
            I-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
            S-CSCF->>P-CSCF: SIP 200 - OK (PRACK)
            P-CSCF->>UE1: SIP 200 - OK (PRACK)
        end

        UE2->>P-CSCF: SIP 200 - OK (INVITE)
        P-CSCF->>PCRF: Diameter - AA-Request (AAR)
        PCRF->>P-CSCF: Diameter - AA-Answer (AAA)
        P-CSCF->>S-CSCF: SIP 200 - OK (INVITE)
        S-CSCF->>I-CSCF: SIP 200 - OK (INVITE)
        I-CSCF->>S-CSCF: SIP 200 - OK (INVITE)
        S-CSCF->>P-CSCF: SIP 200 - OK (INVITE)
        P-CSCF->>PCRF: Diameter - AA-Request (AAR)
        PCRF->>P-CSCF: Diameter - AA-Answer (AAA)
        P-CSCF->>UE1: SIP 200 - OK (INVITE)

        UE1->>P-CSCF: SIP - ACK
        P-CSCF->>S-CSCF: SIP - ACK
        S-CSCF->>I-CSCF: SIP - ACK
        I-CSCF->>S-CSCF: SIP - ACK
        S-CSCF->>P-CSCF: SIP - ACK
        P-CSCF->>UE2: SIP - ACK

        loop Every 30s
            S-CSCF->>OCS: Diameter - Credit-Control-Request (CCR)
            OCS->>S-CSCF: Diameter - Credit-Control-Answer (CCA)
        end

        alt
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            P-CSCF->>UE1: BYE
            UE1->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            P-CSCF->>UE2: BYE
            UE2->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
        else
            UE1->>P-CSCF: BYE
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            P-CSCF->>S-CSCF: BYE
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>UE2: BYE
            UE2->>P-CSCF: OK (BYE)
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: OK (BYE)
            P-CSCF->>UE1: OK (BYE)
        else
            UE2->>P-CSCF: BYE
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            P-CSCF->>S-CSCF: BYE
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>UE1: BYE
            P-CSCF->>PCRF: Diameter - Session-Termination-Request (STR)
            PCRF->>P-CSCF: Diameter - Session-Termination-Answer (STA)
            UE1->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: OK (BYE)
            P-CSCF->>UE2: OK (BYE)
        end
        S-CSCF->>OCS: Diameter - final Credit-Control-Request (CCR)
        OCS->>S-CSCF: Diameter - final Credit-Control-Answer (CCA)
    end
```

### precondition [RFC 3312](https://www.rfc-editor.org/rfc/rfc3312.html) 100rel [RFC 3262](https://www.rfc-editor.org/rfc/rfc3262.html)
SIP:
TS 24.229
Upon generating an initial INVITE request using the precondition mechanism, the UE shall:
- indicate the support for reliable provisional responses and specify it using the Supported header field; and
- indicate the support for the preconditions mechanism and specify it using the *Supported* header field,
The UE shall not indicate the requirement for the precondition mechanism by using the Require header field.
```
Supported: 100rel,precondition
```
SDP:
```
a=des:qos mandatory local sendrecv
a=curr:qos local none
a=des:qos optional remote sendrecv
a=curr:qos remote none
```

### Kamailio
Both P-CSCF and S-CSCF must be able to distinguish between MO & MT.

### Questions:
- What analysis does the S-CSCF perform to determine and discover the correct I-CSCF
  when forwarding requests?
- How the OCS distinguishes originating from terminating Credit-Control-Request (CCR)?
