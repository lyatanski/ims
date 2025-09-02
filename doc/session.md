```mermaid
---
title: Session Control
---
sequenceDiagram
    UE1->>P-CSCF: SIP - INVITE
    P-CSCF->>S-CSCF: SIP - INVITE
    S-CSCF->>OCS: initial orig CCR
    OCS->>S-CSCF: initial orig CCA
    Note over S-CSCF: TS 23.228 5.5.2<br>The Serving-CSCF handling session origination performs an analysis of the destination address<br>and forwards the request to the Interrogating-CSCF for the terminating user.<br>It could be local I-CSCF, if a subscriber of the same operator, or<br>I-CSCF entry point of other operator.
    S-CSCF->>I-CSCF: SIP - INVITE
    I-CSCF->>HSS: LIR
    HSS->>I-CSCF: LIA
    I-CSCF->>S-CSCF: SIP - INVITE
    S-CSCF->>OCS: initial term CCR
    OCS->>S-CSCF: initial term CCA
    S-CSCF->>P-CSCF: SIP - INVITE
    P-CSCF->>UE2: SIP - INVITE
    alt
        UE1->>P-CSCF: SIP - CANCEL
        P-CSCF->>S-CSCF: SIP - CANCEL
        S-CSCF->>I-CSCF: SIP - CANCEL
        I-CSCF->>S-CSCF: SIP - CANCEL
        S-CSCF->>P-CSCF: SIP - CANCEL
        P-CSCF->>UE2: SIP - CANCEL
    else
        UE2->>P-CSCF: SIP 183 - Session Progress
        P-CSCF->>S-CSCF: SIP 183 - Session Progress
        S-CSCF->>P-CSCF: SIP 183 - Session Progress
        P-CSCF->>UE1: SIP 183 - Session Progress
        P-CSCF->>PCRF: AAR
        PCRF->>P-CSCF: AAA
        UE1->>P-CSCF: SIP - PRACK
        P-CSCF->>S-CSCF: SIP - PRACK
        S-CSCF->>P-CSCF: SIP - PRACK
        P-CSCF->>UE2: SIP - PRACK
        UE2->>P-CSCF: SIP 200 - OK (PRACK)
        P-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
        S-CSCF->>P-CSCF: SIP 200 - OK (PRACK)
        P-CSCF->>UE1: SIP 200 - OK (PRACK)

        UE2->>P-CSCF: SIP 180 - Ringing
        P-CSCF->>S-CSCF: SIP 180 - Ringing
        S-CSCF->>P-CSCF: SIP 180 - Ringing
        P-CSCF->>UE1: SIP 180 - Ringing
        UE1->>P-CSCF: SIP - PRACK
        P-CSCF->>S-CSCF: SIP - PRACK
        S-CSCF->>P-CSCF: SIP - PRACK
        P-CSCF->>UE2: SIP - PRACK
        UE2->>P-CSCF: SIP 200 - OK (PRACK)
        P-CSCF->>S-CSCF: SIP 200 - OK (PRACK)
        S-CSCF->>P-CSCF: SIP 200 - OK (PRACK)
        P-CSCF->>UE1: SIP 200 - OK (PRACK)

        UE2->>P-CSCF: SIP 200 - OK (INVITE)
        P-CSCF->>S-CSCF: SIP 200 - OK (INVITE)
        S-CSCF->>P-CSCF: SIP 200 - OK (INVITE)
        P-CSCF->>UE1: SIP 200 - OK (INVITE)
        UE1->>P-CSCF: ACK
        P-CSCF->>S-CSCF: ACK
        S-CSCF->>P-CSCF: ACK
        P-CSCF->>UE2: ACK

        loop Every 30s
            S-CSCF->>OCS: CCR
            OCS->>S-CSCF: CCA
        end

        alt
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            P-CSCF->>UE1: BYE
            UE1->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            P-CSCF->>UE2: BYE
            UE2->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
        else
            UE1->>P-CSCF: BYE
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            P-CSCF->>S-CSCF: BYE
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>UE2: BYE
            UE2->>P-CSCF: OK (BYE)
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: OK (BYE)
            P-CSCF->>UE1: OK (BYE)
        else
            UE2->>P-CSCF: BYE
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            P-CSCF->>S-CSCF: BYE
            S-CSCF->>P-CSCF: BYE
            P-CSCF->>UE1: BYE
            P-CSCF->>PCRF: STR
            PCRF->>P-CSCF: STA
            UE1->>P-CSCF: OK (BYE)
            P-CSCF->>S-CSCF: OK (BYE)
            S-CSCF->>P-CSCF: OK (BYE)
            P-CSCF->>UE2: OK (BYE)
        end
        S-CSCF->>OCS: final CCR
        OCS->>S-CSCF: final CCA
    end
```
