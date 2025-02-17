package main

import (
	"os"
	"fmt"
	"log"
	"net"
	"flag"
	"time"
	"os/exec"
	"context"
	"strconv"
	"github.com/wmnsk/go-gtp/gtpv2"
	"github.com/wmnsk/go-gtp/gtpv2/message"
	"github.com/wmnsk/go-gtp/gtpv2/ie"
	"github.com/vishvananda/netlink"
)

var (
	pgwc = flag.String("pgwc", "smf", "PGWC FQDN/IP")
	mcc = flag.String("mcc", "001", "MCC")
	mnc = flag.String("mnc", "01", "MNC")
	foo string
	gtpu *netlink.GTP
)

func CreateSessionResponse(con *gtpv2.Conn, pgw net.Addr, msg message.Message) error {
	var msIP, upfIP, pcscfIP string
	var oteiU uint32
	var addr netlink.Addr
	var call []string

	log.Println("searching session for TEID", msg.TEID())
	ses, err := con.GetSessionByTEID(msg.TEID(), pgw)
	if err != nil {
		return err
	}

	res := msg.(*message.CreateSessionResponse)
	if fteidcIE := res.PGWS5S8FTEIDC; fteidcIE != nil {
		it, err := fteidcIE.InterfaceType()
		if err != nil {
			return err
		}
		teid, err := fteidcIE.TEID()
		if err != nil {
			return err
		}
		ses.AddTEID(it, teid)
	} else {
		con.RemoveSession(ses)
		return &gtpv2.RequiredIEMissingError{Type: ie.FullyQualifiedTEID}
	}

	if paaIE := res.PAA; paaIE != nil {
		msIP, err = paaIE.IPAddress()
		if err != nil {
			return err
		}
	}

	if pcoIE := res.PCO; pcoIE != nil {
		pco, err := pcoIE.ProtocolConfigurationOptions()
		if err != nil {
			return err
		}
		for _, childIE := range pco.ProtocolOrContainers {
			if childIE.ID == 0xc {
				pcscfIP = fmt.Sprintf("%d.%d.%d.%d", childIE.Contents[0], childIE.Contents[1], childIE.Contents[2], childIE.Contents[3])
			}
		}
	}

	if brCtxIE := res.BearerContextsCreated; brCtxIE != nil {
		for _, childIE := range brCtxIE[0].ChildIEs {
			switch childIE.Type {
			case ie.FullyQualifiedTEID:
				upfIP, err = childIE.IPAddress()
				if err != nil {
					return err
				}
				oteiU, err = childIE.TEID()
			}
		}
	}

	log.Println("MS IP", msIP)
	pdp := &netlink.PDP{
		Version:     1,
		PeerAddress: net.ParseIP(upfIP),
		MSAddress:   net.ParseIP(msIP),
		OTEI:        oteiU,
		ITEI:        msg.TEID(),
	}

	if err := netlink.GTPPDPAdd(gtpu, pdp); err != nil {
		log.Fatal("8 ", ses.IMSI, err)
	}

	link, err := netlink.LinkByName("eth0")
	if err != nil {
		log.Fatal("x ", err)
	}

	addr.IPNet = &net.IPNet{IP: net.ParseIP(msIP), Mask: net.CIDRMask(24, 32)}
	if err := netlink.AddrAdd(link, &addr); err != nil {
		log.Fatal("9 ", err)
	}

	route := &netlink.Route{
		Dst:       &net.IPNet{IP: net.IPv4zero, Mask: net.CIDRMask(0, 32)}, // default
		LinkIndex: gtpu.Attrs().Index,
		Scope:     netlink.SCOPE_LINK,
		Protocol:  4,
		Priority:  1,
		Table:     1001,
	}
	if err := netlink.RouteReplace(route); err != nil {
		log.Fatal("10 ", err)
	}

	rules, err := netlink.RuleList(0)
	if err != nil {
		log.Fatal("11 ", err)
	}

	mask32 := &net.IPNet{IP: net.ParseIP(msIP), Mask: net.CIDRMask(32, 32)}
	for _, r := range rules {
		if r.Src == mask32 && r.Table == 1001 {
			return nil // Rule already exists, no need to add
		}
	}

	rule := netlink.NewRule()
	//rule.IifName = "gtp0"
	rule.Src = mask32
	rule.Table = 1001

	if err := netlink.RuleAdd(rule); err != nil {
		log.Fatal("12 ", err)
	}

	log.Println("before starting process", ses.IMSI)
	call = append(call, "/opt/sip.py", "--imsi", ses.IMSI, "--msisdn", fmt.Sprintf("%s%0.9d", os.Getenv("DIAL"), msg.TEID()), "--bind", msIP)
	if msg.TEID() % 2 == 0 {
		call = append(call, "--call", fmt.Sprintf("%s%0.9d", os.Getenv("DIAL"), msg.TEID()-1))
	}
	call = append(call, pcscfIP)
	cmd := exec.Command("python3", call...)
	log.Println(cmd)
	out, err := cmd.CombinedOutput()
	log.Println(string(out))
	if err != nil {
		log.Fatal("13 ", err)
	}
	log.Println("process finished")

	return nil
}

func CreateBearerRequest(con *gtpv2.Conn, pgw net.Addr, msg message.Message) error {
	ses, err := con.GetSessionByIMSI(fmt.Sprintf("%s%s%0.10d", *mcc, *mnc, 1))
	if err != nil {
		return err
	}
	teid, err := ses.GetTEID(gtpv2.IFTypeS5S8PGWGTPC)
	if err != nil {
		return err
	}
	req := msg.(*message.CreateBearerRequest)
	res := message.NewCreateBearerResponse(
		teid, req.SequenceNumber,
		ie.NewCause(gtpv2.CauseRequestAccepted, 0, 0, 0, nil),
		ie.NewBearerContext(
			ie.NewCause(gtpv2.CauseRequestAccepted, 0, 0, 0, nil),
			ie.NewEPSBearerID(5),
			ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPU, uint32(1), foo, ""),
			ie.NewBearerQoS(1, 1, 1, 1, 0x52, 0x52, 0x52, 0x52),
		),
	)
	payload, err := message.Marshal(res)
	if err != nil {
		return err
	}
	_, err = con.WriteTo(payload, pgw)
	return err
}

func ModifyBearerResponse(con *gtpv2.Conn, pgw net.Addr, msg message.Message) error {
	return nil
}

func DeleteSessionResponse(con *gtpv2.Conn, pgw net.Addr, msg message.Message) error {
	return nil
}

func ResolveLocalAddr(port string) string {
	con, err := net.Dial("udp", *pgwc+port)
	if err != nil {
		log.Fatal(err)
	}
	defer con.Close()
	return con.LocalAddr().(*net.UDPAddr).IP.String()
}

func main() {
	flag.Parse()
	ctx := context.Background()
	pgw, err := net.ResolveUDPAddr("udp", *pgwc+gtpv2.GTPCPort)
	if err != nil {
		log.Fatal(err)
	}
	foo = ResolveLocalAddr(gtpv2.GTPCPort)
	bind, err := net.ResolveUDPAddr("udp", "0.0.0.0"+gtpv2.GTPCPort)
	con, err := gtpv2.Dial(ctx, bind, pgw, gtpv2.IFTypeS5S8SGWGTPC, 0)
	if err != nil {
		log.Fatal("0 ", err)
	}
	defer con.Close()

	usr0, err := net.ListenPacket("udp", "0.0.0.0:3386")
	if err != nil {
		log.Fatal("1 ", err)
	}
	defer usr0.Close()

	f0, err := usr0.(*net.UDPConn).File()
	if err != nil {
		log.Fatal("3 ", err)
	}

	usr1, err := net.ListenPacket("udp", "0.0.0.0"+gtpv2.GTPUPort)
	if err != nil {
		log.Fatal("2 ", err)
	}
	defer usr1.Close()

	f1, err := usr1.(*net.UDPConn).File()
	if err != nil {
		log.Fatal("4 ", err)
	}

	gtpu = &netlink.GTP{
		LinkAttrs: netlink.LinkAttrs{
			Name: "gtp0",
		},
		FD0:  int(f0.Fd()),
		FD1:  int(f1.Fd()),
		Role: 1,
	}

	if err := netlink.LinkAdd(gtpu); err != nil {
		log.Fatal("5 ", err)
	}
	//defer netlink.LinkDel(gtpu)

	if err := netlink.LinkSetUp(gtpu); err != nil {
		log.Fatal("6 ", err)
	}

	if err := netlink.LinkSetMTU(gtpu, 1500); err != nil {
		log.Fatal("7 ", err)
	}

	con.AddHandlers(map[uint8]gtpv2.HandlerFunc{
		message.MsgTypeCreateSessionResponse: CreateSessionResponse,
		message.MsgTypeCreateBearerRequest:   CreateBearerRequest,
		message.MsgTypeModifyBearerResponse:  ModifyBearerResponse,
		message.MsgTypeDeleteSessionResponse: DeleteSessionResponse,
	})

	ues, err := strconv.Atoi(os.Getenv("SCALE"))
	if err != nil {
		log.Fatal(err)
	}
	for i := 1; i <= ues; i++ {
		ses, _, err := con.CreateSession(
			pgw,
			ie.NewIMSI(fmt.Sprintf("%s%s%0.10d", *mcc, *mnc, i)),
			ie.NewServingNetwork(*mcc, *mnc),
			ie.NewRATType(gtpv2.RATTypeEUTRAN),
			ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPC, uint32(i), foo, ""),
			ie.NewAccessPointName("ims"),
			ie.NewProtocolConfigurationOptions(
				gtpv2.ConfigProtocolPPPWithIP,
				ie.NewPCOContainer(gtpv2.ProtoIDIPCP, []byte{0x01, 0x00, 0x00, 0x10, 0x03, 0x06, 0x01, 0x01, 0x01, 0x01, 0x81, 0x06, 0x02, 0x02, 0x02, 0x02}),
				ie.NewPCOContainer(0x000c, nil),
			),
			ie.NewSelectionMode(gtpv2.SelectionModeMSorNetworkProvidedAPNSubscribedVerified),
			ie.NewPDNType(gtpv2.PDNTypeIPv4),
			ie.NewPDNAddressAllocation("0.0.0.0"),
			ie.NewAPNRestriction(gtpv2.APNRestrictionNoExistingContextsorRestriction),
			ie.NewAggregateMaximumBitRate(0x11111111, 0x22222222),
			ie.NewUserLocationInformation(0, 0, 0, 0, 0, 0, 0, 0,
				*mcc, *mnc, 1, 1, 1, 1, 1,
				1, 1, 1,
			),
			ie.NewBearerContext(
				ie.NewEPSBearerID(5),
				ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPU, uint32(i), foo, "").WithInstance(2),
				ie.NewBearerQoS(1, 2, 1, 0xff, 0, 0, 0, 0),
			),
		)
		if err != nil {
			log.Fatal(err)
		}
		log.Println(ses)
	}

	//time.Sleep(8 * time.Second)

	//teid, err := ses.GetTEID(gtpv2.IFTypeS5S8PGWGTPC)
	//if err != nil {
	//	log.Fatal(err)
	//}
	//con.DeleteSession(
	//	teid,
	//	ses,
	//	ie.NewEPSBearerID(ses.GetDefaultBearer().EBI),
	//)
	time.Sleep(300 * time.Second)
}
