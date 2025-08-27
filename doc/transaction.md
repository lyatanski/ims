```mermaid
---
title: Transaction
---
sequenceDiagram
    UE1->>P-CSCF: SIP - MESSAGE
    P-CSCF->>S-CSCF: SIP - MESSAGE
    S-CSCF->>AS: SIP - MESSAGE
    AS->>S-CSCF: SIP - MESSAGE
    S-CSCF->>P-CSCF: SIP - MESSAGE
    P-CSCF->>UE1: SIP - MESSAGE
```
