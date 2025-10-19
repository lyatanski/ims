# Tracing

Tracing IMS (IP Multimedia Subsystem) traffic can be achieved using several approaches, each with distinct advantages and limitations.

## [tcpdump](https://www.tcpdump.org/)
**Overview:**  
`tcpdump` provides the most complete view of network activity by capturing all packets on an interface.

**Pros:**
- Captures all traffic types (SIP, Diameter, DNS, TCP handshakes, etc.).  
- Independent of application logic or protocol implementation.

**Cons:**
- Requires one capture per container, adding complexity in multi-container environments.  
- In Docker Compose setups, a single `tcpdump` for the entire network is possible but may produce prohibitively large capture files.  
- Combining multiple container captures into a single call flow trace can be cumbersome.  
- Real-time observation is not straightforward.


## [siptrace](https://kamailio.org/docs/modules/devel/modules/siptrace.html) (Kamailio module)
**Overview:**  
The Kamailio `siptrace` module enables SIP message tracing and supports exporting data to HEP-compatible collectors such as [Homer](https://github.com/sipcapture/homer).

**Pros:**
- Integrates easily with HEP-based monitoring tools.  
- Offers flexible storage and retrieval options for SIP traces.

**Cons:**
- Primarily supports SIP

## [captagent](https://github.com/sipcapture/captagent)
**Overview:**  
`captagent` acts as a HEP-compatible packet capture agent that can forward captured SIP and Diameter messages to tools like Homer.

**Pros:**
- HEP-compatible and integrates seamlessly with Homer.  
- Supports multiple protocols (SIP, Diameter, etc.).  
- Serves as a middle ground between full network capture (`tcpdump`) and application-level tracing (`siptrace`).

**Cons:**
- Typically requires an additional container per monitored container


## custom eBPF powered HEP Agent?


## Summary Comparison

| Tool | Scope | HEP-Compatible | Protocols | Deployment Overhead | Notes |
|------|--------|----------------|------------|----------------------|--------|
| **tcpdump** | All network traffic | No | All | High | Comprehensive but large and complex captures |
| **siptrace** | SIP-level | Yes | SIP | Low–Medium | Tight Kamailio integration |
| **captagent** | Selected protocols | Yes | SIP, Diameter | Medium | Balanced approach, integrates with Homer |
