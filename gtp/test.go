package main

import (
	"fmt"
	"log"
	"net"
	"flag"
	"time"
	"context"
	"github.com/wmnsk/go-gtp/gtpv2"
	"github.com/wmnsk/go-gtp/gtpv2/message"
	"github.com/wmnsk/go-gtp/gtpv2/ie"
)

var (
	pgwc = flag.String("pgwc", "smf", "PGWC FQDN/IP")
	mcc = flag.String("mcc", "001", "MCC")
	mnc = flag.String("mnc", "01", "MNC")
	bind *net.UDPAddr
)

func CreateSessionResponse(con *gtpv2.Conn, pgw net.Addr, msg message.Message) error {
	ses, err := con.GetSessionByIMSI(fmt.Sprintf("%s%s%0.10d", *mcc, *mnc, 1))
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
			ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPU, uint32(1), bind.IP.String(), ""),
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

func ResolveLocalAddr() (*net.UDPAddr, error) {
	con, err := net.Dial("udp", *pgwc+gtpv2.GTPCPort)
	if err != nil {
		log.Fatal(err)
	}
	defer con.Close()
	ip := con.LocalAddr().(*net.UDPAddr)
	return ip, err
}

func main() {
	ctx := context.Background()
	pgw, err := net.ResolveUDPAddr("udp", *pgwc+gtpv2.GTPCPort)
	if err != nil {
		log.Fatal(err)
	}
	bind, err = ResolveLocalAddr()
	if err != nil {
		log.Fatal(err)
	}
	con, err := gtpv2.Dial(ctx, bind, pgw, gtpv2.IFTypeS5S8SGWGTPC, 0)
	if err != nil {
		log.Fatal(err)
	}
	defer con.Close()

	con.AddHandlers(map[uint8]gtpv2.HandlerFunc{
		message.MsgTypeCreateSessionResponse: CreateSessionResponse,
		message.MsgTypeCreateBearerRequest:   CreateBearerRequest,
		message.MsgTypeModifyBearerResponse:  ModifyBearerResponse,
		message.MsgTypeDeleteSessionResponse: DeleteSessionResponse,
	})

	ses, _, err := con.CreateSession(
		pgw,
		ie.NewIMSI(fmt.Sprintf("%s%s%0.10d", *mcc, *mnc, 1)),
		ie.NewServingNetwork(*mcc, *mnc),
		ie.NewRATType(gtpv2.RATTypeEUTRAN),
		ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPC, uint32(1), bind.IP.String(), ""),
		ie.NewAccessPointName("ims"),
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
			ie.NewFullyQualifiedTEID(gtpv2.IFTypeS5S8SGWGTPU, uint32(1), bind.IP.String(), "").WithInstance(2),
			ie.NewBearerQoS(1, 2, 1, 0xff, 0, 0, 0, 0),
		),
	)
	if err != nil {
		log.Fatal(err)
	}

	time.Sleep(8 * time.Second)

	teid, err := ses.GetTEID(gtpv2.IFTypeS5S8PGWGTPC)
	if err != nil {
		log.Fatal(err)
	}
	con.DeleteSession(
		teid,
		ses,
		ie.NewEPSBearerID(ses.GetDefaultBearer().EBI),
	)
}
