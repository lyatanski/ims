#!/usr/bin/python3

import os
import sys
import time
import logging
import threading
import tinyWRAP as s

class DDebugCallback(s.DDebugCallback):
    def __init__(self):
        super().__init__()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass

    def OnDebugInfo(self, msg):
        logging.info(msg)
        return 0

    def OnDebugWarn(self, msg):
        logging.warning(msg)
        return 0

    def OnDebugError(self, msg):
        logging.error(msg)
        return 0

    def OnDebugFatal(self, msg):
        logging.critical(msg)
        return 0


ct = None
def talk(call):
    call.accept()
    time.sleep(40)
    call.hangup()

class SipCallback(s.SipCallback):
    def __init__(self, imsi, msisdn, domain):
        super().__init__()
        self.imsi = imsi
        self.msisdn = msisdn
        self.domain = domain
        self.__disown__()

    def OnDialogEvent(self, event):
        logging.info(f"dialog")
        return 0

    def OnStackEvent(self, event):
        logging.info(f"stack {event.getStack()} {event.getPhrase()}")
        if event.getPhrase() == "Stack stopped":
            pass
        if event.getPhrase() == "Stack started":
            reg = s.RegistrationSession(event.getStack())
            reg.addCaps("+g.3gpp.smsip", "") # for SMS support
            reg.register_()
        return 0

    def OnInviteEvent(self, event):
        logging.info(f"invite {event.getStack()} type {event.getType()}")
        msg = event.getSipMessage()
        if not msg: return 0
        if not msg.isResponse():
            logging.info(f"should accept invite on session {event.getSession()}")
            if not event.getSession():
                call = event.takeCallSessionOwnership()
                call.setSessionTimer(3600, "none")
                call.setQoS(s.tmedia_qos_strength_optional, s.tmedia_qos_strength_optional)
                ct = threading.Timer(1, talk, (call,))
                ct.start()
        return 0

    def OnMessagingEvent(self, event):
        logging.info(f"message")
        return 0

    def OnInfoEvent(self, event):
        logging.info(f"info")
        return 0

    def OnOptionsEvent(self, event):
        logging.info(f"options")
        return 0

    def OnPublicationEvent(self, event):
        logging.info(f"publication")
        return 0

    def OnRegistrationEvent(self, event):
        logging.info(f"registration {event.getStack()} type {event.getType()}")
        msg = event.getSipMessage()
        if not msg: return 0
        if msg.isResponse() and msg.getResponseCode() == 200:
            logging.info(f"sending subscribe")
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
        logging.info(f"subscription {event.getStack()} type {event.getType()}")
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

        sip.addHeader("P-Access-Network-Info", "3GPP-E-UTRAN-FDD;utran-cell-id-3gpp=4250319f10053212")

        if(ipsec):
            if(not sip.setIPsecPlugin(ipsec)): sys.exit(1)
            sip.setIPSecSecAgree(True)
            sip.setIPSecParameters("hmac-md5-96", "null", "trans", "esp")

        sip.start()

        return sip
    return run_ue


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(prog="IMS SIP client")
    parser.add_argument('--bind', help="local bind IP")
    parser.add_argument('--imsi', help="International Mobile Subscriber Identity")
    parser.add_argument('--msisdn', help="Mobile Station International Subscriber Directory Number")
    parser.add_argument('--call', help="MSISDN to call")
    parser.add_argument('cscf', help="CSCF IP address")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format=f"%(levelname)8s {args.imsi}:%(message)s")
    logging.info(" ".join(sys.argv))

    with DDebugCallback():
        run = gen(cscf=args.cscf, domain=os.environ["REALM"], ipsec=os.environ["IPSEC"])
        s0 = run(imsi = args.imsi,
                 msisdn = args.msisdn,
                 Ki = os.environ["K"],
                 opc = os.environ["OPC"],
                 bind = args.bind)

        time.sleep(6)

        if args.call:
            #s0.removeHeader("Event")
            call = s.CallSession(s0)
            #call.set100rel(True)
            #call.setSessionTimer(3600, "none")
            call.setQoS(s.tmedia_qos_strength_optional, s.tmedia_qos_strength_optional)
            call.call(f'sip:{args.call}@{os.environ["REALM"]};user=phone', s.twrap_media_audio)

            #time.sleep(10)
            #call.hold()
            #time.sleep(10)
            #call.resume()

            time.sleep(60)
            call.hangup()
        else:
            time.sleep(6)
            if ct: ct.join(60)
            else: time.sleep(60)

        time.sleep(30)

        #del s0
        # wait for OK on REGISTER Expires: 0

    time.sleep(3)

