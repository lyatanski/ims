#!/usr/bin/python3

import os
import sys
#import time
import logging
import tinyWRAP as s

class SipCallback(s.SipCallback):
    def __init__(self, imsi, msisdn, call):
        super().__init__()
        self.log = logging.getLogger(f"----------{imsi}----------")
        self.imsi = imsi
        self.msisdn = msisdn
        self.call = call
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
            sip.setIMPU(f"sip:{self.msisdn}@{domain}")
            sip.setRealm(f"sip:{self.msisdn}@{domain}")
            sip.addHeader("Event", "reg")
            sip.addHeader("Accept", "application/reginfo+xml")
            #sip.setSilentHangup(True)
            s.SubscriptionSession(sip).subscribe()
        return 0

    def OnSubscriptionEvent(self, event):
        self.log.info(f"subscription {event.getStack()} type {event.getType()}")
        msg = event.getSipMessage()
        if not msg: return 0
        if msg.isResponse() and msg.getResponseCode() == 200:
            if self.call:
                sip = event.getStack()
                sip.removeHeader("Event")
                call = s.CallSession(sip)
                #call.set100rel(True)
                call.setSessionTimer(3600, "none")
                call.setQoS(s.tmedia_qos_stype_none, s.tmedia_qos_strength_none)
                call.call(f"tel:{self.call};phone-context=", s.twrap_media_audio)
        #if event.getType() == s.tsip_i_notify and self.call:
        #    sip = event.getStack()
        #    sip.removeHeader("Event")
        #    s.CallSession(sip).call(f"tel:{self.call};phone-context=", s.twrap_media_audio)
        return 0


def gen(cscf, domain, proto="udp"):
    def run_ue(imsi, msisdn, Ki, opc, bind=None, ipsec=None, call=None):
        sip = s.SipStack(SipCallback(imsi, msisdn, call),
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
    run = gen(cscf=sys.argv[1], domain=sys.argv[2])
    s0 = run(imsi = os.environ["IMSI"],
             msisdn = os.environ["MSISDN"],
             Ki = os.environ["K"],
             opc = os.environ["OPC"])
    #time.sleep(10)
    #del s0

