package main

// webshark - Wireshark in the browser. Static page plus a JSON API over sharkd,
// which does all the dissecting.
//
//	GET  /                              the UI (embedded, or WEB=<dir> to serve
//	                                    it off disk while working on it)
//	GET  /api/captures                  files in CAPTURES, and which are open
//	GET  /api/status?f=                 frame count, columns, duration
//	GET  /api/frames?f=&filter=&skip=&limit=
//	GET  /api/frame?f=&num=&prev=       dissection tree and bytes
//	GET  /api/addresses?f=&filter=      how many addresses the diagram would need
//	GET  /api/check?f=&filter=          compile a display filter
//	GET  /api/file?f=                   download a capture
//	POST /api/file?f=                   upload one (raw body)
//	POST /api/close?f=                  end that capture's sharkd
//
// Responses are sharkd's own JSON, forwarded without being decoded, except for
// /api/frames: sharkd repeats every pcapng frame comment in the packet list, and
// a ptcpdump capture carries ~1.4 kB of container metadata per frame, which is
// 20x the size of the columns the list actually draws. That one is decoded and
// trimmed to what the UI reads.
//
// There is one thing to run instead of the server:
//
//	webshark -esp <capture>          the capture's ESP SAs, as esp_sa records
//
// which is the list every sharkd started here is given anyway (esp.go).

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"time"
)

//go:embed web
var embedded embed.FS

// A capture name is a bare file name in CAPTURES - no separators, no leading
// dot - which is the whole of the path handling here.
var nameOK = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,127}$`)

type server struct {
	dir  string
	pool *pool
}

func main() {
	// `webshark -esp <capture>` prints the ESP SAs of one capture and exits, for
	// the programs next to this one that read Wireshark's esp_sa file instead of
	// asking a server. A path, not a name in CAPTURES: this is a command line.
	if len(os.Args) > 1 && os.Args[1] == "-esp" {
		if len(os.Args) != 3 {
			log.Fatal("usage: webshark -esp <capture>")
		}
		records, err := espSAs(env("TSHARK", "tshark"), os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		for _, record := range records {
			fmt.Println(record)
		}
		return
	}

	srv := &server{dir: env("CAPTURES", "/captures")}
	srv.pool = newPool(
		env("SHARKD", "sharkd"), env("TSHARK", "tshark"), srv.dir,
		atoi(env("SHARKD_SESSIONS", "4"), 4),
		time.Duration(atoi(env("SHARKD_IDLE", "600"), 600))*time.Second,
	)

	var web http.FileSystem
	if dir := os.Getenv("WEB"); dir != "" {
		web = http.Dir(dir)
	} else {
		sub, err := fs.Sub(embedded, "web")
		if err != nil {
			log.Fatal(err)
		}
		web = http.FS(sub)
	}

	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServer(web))
	mux.HandleFunc("GET /api/captures", srv.captures)
	mux.HandleFunc("GET /api/status", srv.status)
	mux.HandleFunc("GET /api/frames", srv.frames)
	mux.HandleFunc("GET /api/frame", srv.frame)
	mux.HandleFunc("GET /api/addresses", srv.addresses)
	mux.HandleFunc("GET /api/check", srv.check)
	mux.HandleFunc("GET /api/file", srv.download)
	mux.HandleFunc("POST /api/file", srv.upload)
	mux.HandleFunc("POST /api/close", srv.close)

	addr := env("LISTEN", ":8085")
	log.Printf("webshark on %s, captures in %s", addr, srv.dir)
	// no explicit host, so this listens on v4 and v6 both - the published port
	// needs no address pinned to it
	log.Fatal(http.ListenAndServe(addr, mux))
}

// ------------------------------------------------------------------ captures --

func (s *server) captures(w http.ResponseWriter, r *http.Request) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		fail(w, http.StatusInternalServerError, err)
		return
	}
	open := s.pool.open()

	type capture struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
		Open bool   `json:"open"`
	}
	out := []capture{}
	for _, e := range entries {
		if e.IsDir() || !nameOK.MatchString(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, capture{e.Name(), info.Size(), slices.Contains(open, e.Name())})
	}
	send(w, out)
}

func (s *server) download(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Disposition", "attachment; filename=\""+name+"\"")
	http.ServeFile(w, r, filepath.Join(s.dir, name))
}

// Streamed to disk rather than buffered, so the size of an upload is a disk
// question and not a memory one.
func (s *server) upload(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	// O_EXCL: an upload must not quietly replace a capture, least of all the one
	// ptcpdump is writing
	f, err := os.OpenFile(filepath.Join(s.dir, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if os.IsExist(err) {
		fail(w, http.StatusConflict, name+" is already there")
		return
	}
	if err != nil {
		fail(w, http.StatusInternalServerError, err)
		return
	}
	defer f.Close()
	n, err := io.Copy(f, r.Body)
	if err != nil {
		fail(w, http.StatusInternalServerError, err)
		return
	}
	send(w, map[string]any{"name": name, "size": n})
}

func (s *server) close(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	s.pool.closeFile(name)
	send(w, map[string]any{"closed": name})
}

// -------------------------------------------------------------------- sharkd --

func (s *server) status(w http.ResponseWriter, r *http.Request) {
	s.forward(w, r, "status", nil)
}

func (s *server) frame(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	num := atoi(q.Get("num"), 0)
	if num <= 0 {
		fail(w, http.StatusBadRequest, "num?")
		return
	}
	params := map[string]any{"frame": num, "proto": true, "bytes": true}
	// the delta-time column is relative to the previously displayed frame, so
	// the list tells sharkd which one that was
	if prev := atoi(q.Get("prev"), 0); prev > 0 {
		params["prev_frame"] = prev
	}
	s.forward(w, r, "frame", params)
}

// addresses counts the distinct endpoints of a capture, which is how many columns
// the sequence diagram would need to draw all of it. The endpoints tap is one pass
// over the whole file, so the diagram can say up front that it has more addresses
// than it draws - the UI's own node list is built from the pages fetched so far and
// only finds that out when the frame that overflows it scrolls into view.
//
// Endpoints are IP ones: a frame with no network layer (ARP, STP) shows a MAC in
// the address columns and becomes a node in the diagram too, so this is a floor
// rather than the total, and the UI keeps counting as it pages for that reason.
// Wireshark's own flow-graph tap (seqa) is no use here - it truncates to the same
// 40 nodes the diagram does, so it cannot report the overflow it is hiding.
func (s *server) addresses(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	params := map[string]any{"tap0": "endpt:IPv4", "tap1": "endpt:IPv6"}
	if filter := r.URL.Query().Get("filter"); filter != "" {
		params["filter"] = filter
	}
	raw, err := s.pool.call(name, "tap", params)
	if err != nil {
		fail(w, http.StatusBadRequest, err)
		return
	}
	var taps struct {
		Taps []struct {
			Hosts []struct {
				Host string `json:"host"`
			} `json:"hosts"`
		} `json:"taps"`
	}
	if err := json.Unmarshal(raw, &taps); err != nil {
		fail(w, http.StatusInternalServerError, err)
		return
	}
	// the two taps are disjoint address spaces, but count a set rather than rely
	// on that
	seen := map[string]bool{}
	for _, tap := range taps.Taps {
		for _, h := range tap.Hosts {
			seen[h.Host] = true
		}
	}
	send(w, map[string]any{"n": len(seen)})
}

func (s *server) check(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	if _, err := s.pool.call(name, "check", map[string]any{"filter": r.URL.Query().Get("filter")}); err != nil {
		send(w, map[string]any{"ok": false, "err": err.Error()})
		return
	}
	send(w, map[string]any{"ok": true})
}

// frames is the one response the UI cannot use as it stands: see the note at the
// top. A row is the columns and the frame number, which is all the list draws.
func (s *server) frames(w http.ResponseWriter, r *http.Request) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit := min(atoi(q.Get("limit"), 200), 5000)
	skip := atoi(q.Get("skip"), 0)
	// No page begins before the first frame and none holds no frames. Saying so
	// beats answering with what is left once the parameter is dropped, which is
	// page 0 - rows the caller then reads as the page it asked for.
	if skip < 0 || limit < 1 {
		fail(w, http.StatusBadRequest, "skip/limit?")
		return
	}
	params := map[string]any{"limit": limit}
	// sharkd validates every numeric parameter as "positive", zero included, so
	// the first page has to leave `skip` out rather than send 0
	if skip > 0 {
		params["skip"] = skip
	}
	if filter := q.Get("filter"); filter != "" {
		params["filter"] = filter
	}
	raw, err := s.pool.call(name, "frames", params)
	if err != nil {
		fail(w, http.StatusBadRequest, err)
		return
	}

	var in []struct {
		Columns []string `json:"c"`
		Num     int      `json:"num"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		fail(w, http.StatusInternalServerError, err)
		return
	}

	type row struct {
		Num     int      `json:"n"`
		Columns []string `json:"c"`
	}
	rows := make([]row, len(in))
	for i, f := range in {
		rows[i] = row{f.Num, f.Columns}
	}
	// a short page is the end of the capture, or of the filtered set - which is
	// the only way to know, since sharkd will not count matches without
	// dissecting the file
	send(w, map[string]any{"rows": rows, "end": len(rows) < limit})
}

func (s *server) forward(w http.ResponseWriter, r *http.Request, method string, params any) {
	name, ok := s.name(w, r)
	if !ok {
		return
	}
	raw, err := s.pool.call(name, method, params)
	if err != nil {
		fail(w, http.StatusBadRequest, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(raw)
}

// --------------------------------------------------------------------- plumb --

// Parameters are read from the query string only, never with FormValue: an
// upload arrives as a raw body, and form parsing would eat it.
func (s *server) name(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.URL.Query().Get("f")
	if !nameOK.MatchString(name) {
		fail(w, http.StatusBadRequest, "f?")
		return "", false
	}
	return name, true
}

func send(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, reason any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"err": sprint(reason)})
}

func sprint(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case error:
		return t.Error()
	}
	return "error"
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func atoi(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}
