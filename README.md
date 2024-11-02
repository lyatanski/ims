# IMS
IP Multimedia Subsystem

Why another setup:
- use modern compose fetures (like interpolation) for simplicity
- go into a bit more depth of the Kamailio configuration for better understanding
- provide entirely software based playground for testing

The minimal IMS is comprised of 3 Call Session Control Functions (CSCF):
- Proxy
- Interrogating
- Serving

Required core network components:
- Home subscriber server (HSS)
- Policy and Charging Rules Function (PCRF)

Additionally DNS will be required for services name resolution as the naming convention follows the pattern: <service>.mncXXX.mccXXX.3gppnetwork.org. It is not strictly necessary to follow this naming for test setup and there is a workaround with FQDN compose servive names, but the closer to real setup we can get, the better.
