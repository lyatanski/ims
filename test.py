#!/usr/bin/python3

import os
import sys
import time
import logging
import tinyWRAP as s

class SipCallback(s.SipCallback):
    def __init__(self, imsi, msisdn, domain):
        super().__init__()
        self.log = logging.getLogger(f"----------{imsi}----------")
        self.imsi = imsi
        self.msisdn = msisdn
        self.domain = domain
        self.__disown__()

    def OnDialogEvent(self, event):
        self.log.info(f"dialog")
        return 0

    def OnStackEvent(self, event):
        self.log.info(f"stack {event.getStack()} {event.getPhrase()}")
        if event.getPhrase() == "Stack stopped":
            pass
        if event.getPhrase() == "Stack started":
            reg = s.RegistrationSession(event.getStack())
            reg.addCaps("+g.3gpp.smsip", "") # for SMS support
            reg.register_()
        return 0

    def OnInviteEvent(self, event):
        self.log.info(f"invite {event.getStack()} type {event.getType()}")
        msg = event.getSipMessage()
        if not msg: return 0
        if not msg.isResponse():
            self.log.info(f"should accept invite on session {event.getSession()}")
            if not event.getSession():
                call = event.takeCallSessionOwnership()
                call.setSessionTimer(3600, "none")
                call.setQoS(s.tmedia_qos_stype_none, s.tmedia_qos_strength_none)
                call.accept()
            self.log.info(f"after accept")
        return 0

    def OnMessagingEvent(self, event):
        self.log.info(f"message")
        return 0

    def OnInfoEvent(self, event):
        self.log.info(f"info")
        return 0

    def OnOptionsEvent(self, event):
        self.log.info(f"options")
        return 0

    def OnPublicationEvent(self, event):
        self.log.info(f"publication")
        return 0

    def OnRegistrationEvent(self, event):
        self.log.info(f"registration {event.getStack()} type {event.getType()}")
        msg = event.getSipMessage()
        if not msg: return 0
        if msg.isResponse() and msg.getResponseCode() == 200:
            self.log.info(f"sending subscribe")
            sip = event.getStack()
            sip.setIMPU(f"sip:{self.msisdn}@{self.domain}")
            #sip.setRealm(f"sip:{self.msisdn}@{self.domain}")
            sip.addHeader("Event", "reg")
            sip.addHeader("Accept", "application/reginfo+xml")
            #sip.setSilentHangup(True)
            ses = s.SubscriptionSession(sip)
            ses.setToUri(f"sip:{self.msisdn}@{self.domain}")
            ses.subscribe()
        return 0

    def OnSubscriptionEvent(self, event):
        self.log.info(f"subscription {event.getStack()} type {event.getType()}")
        return 0


def gen(cscf, domain, transport="tcp", ipsec=None):
    def run_ue(imsi, msisdn, Ki, opc, bind=None):
        sip = s.SipStack(SipCallback(imsi, msisdn, domain),
                         realm_uri=domain,
                         impi_uri=f"{imsi}@{domain}",
                         impu_uri=f"sip:{imsi}@{domain}")
        sip.setProxyCSCF(cscf, 5060, transport, "ipv4")

        sip.setLocalPort(5060, transport)
        if bind: sip.setLocalIP(bind, transport)

        # Milenage parameters
        sip.setAMF("8000")
        sip.setPassword(Ki)
        sip.setOperatorIdConcealed(opc)

        if(ipsec):
            if(not sip.setIPsecPlugin(ipsec)): sys.exit(1)
            sip.setIPSecSecAgree(True)
            sip.setIPSecParameters("hmac-md5-96", "null", "trans", "esp")

        sip.start()

        return sip
    return run_ue


if __name__ == "__main__":
    import subprocess
    idx = int(subprocess.check_output("host $(hostname -i) | grep -o 'ims-test-\([0-9]\+\)' | cut -d - -f 3", shell=True).decode("utf-8").strip())
    run = gen(cscf=os.environ["PCSCF"], domain=os.environ["REALM"], ipsec=os.environ["IPSEC"])
    time.sleep(50+idx*3)
    s0 = run(imsi = f'{os.environ["PLMN"]}{idx:010}',
             msisdn = f'{os.environ["DIAL"]}{idx:09}',
             Ki = os.environ["K"],
             opc = os.environ["OPC"])

    time.sleep(10)

    #s0.removeHeader("Event")
    call = s.CallSession(s0)
    #call.set100rel(True)
    #call.setSessionTimer(3600, "none")
    #call.setQoS(s.tmedia_qos_stype_none, s.tmedia_qos_strength_none)
    call.call(f'tel:{os.environ["DIAL"]}{idx-1:09};phone-context=', s.twrap_media_audio)

    time.sleep(10)

    #del s0

