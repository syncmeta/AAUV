package aauvcore

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

const maxNodeLink = 16384

type nodeLink struct {
	name     string
	kind     string
	insecure bool
	outbound map[string]any
}

// InspectNodeLink returns only a display label and capabilities.
func InspectNodeLink(link string) (string, error) {
	node, err := parseNodeLink(link)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(map[string]any{"name": node.name, "kind": node.kind, "insecure": node.insecure})
	return string(data), err
}

// BuildSingBoxNode builds a single outbound and the platform's local inbound.
func BuildSingBoxNode(link, platform string, port int, allowInsecure bool) (string, error) {
	node, err := parseNodeLink(link)
	if err != nil {
		return "", err
	}
	if node.insecure && !allowInsecure {
		return "", errors.New("node_requires_insecure_confirmation")
	}
	route := map[string]any{"final": "node", "default_domain_resolver": "bootstrap"}
	dns := map[string]any{"servers": []map[string]any{{"type": "local", "tag": "bootstrap"}}, "final": "bootstrap"}
	var inbound map[string]any
	switch platform {
	case "macos":
		if port == 0 {
			port, err = suggestLoopbackProxyPort()
			if err != nil {
				return "", err
			}
		}
		if port < 1024 || port > 65535 {
			return "", errors.New("invalid_local_proxy_port")
		}
		inbound = map[string]any{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}
	case "ios":
		inbound = map[string]any{"type": "tun", "address": []string{"172.19.0.1/30", "fdfe:dcba:9876::1/126"}, "mtu": 1500, "auto_route": true, "stack": "gvisor"}
		dns["servers"] = append(dns["servers"].([]map[string]any), map[string]any{
			"type": "https", "tag": "tunnel-dns", "server": "1.1.1.1", "detour": "node",
			"tls": map[string]any{"enabled": true, "server_name": "cloudflare-dns.com"},
		})
		dns["final"] = "tunnel-dns"
		route["auto_detect_interface"] = true
		route["rules"] = []map[string]any{
			{"action": "sniff"},
			{"protocol": "dns", "action": "hijack-dns"},
			{"ip_is_private": true, "action": "route", "outbound": "direct"},
		}
	default:
		return "", errors.New("unsupported_proxy_platform")
	}
	config := map[string]any{
		"log":       map[string]any{"level": "warn"},
		"inbounds":  []map[string]any{inbound},
		"outbounds": []map[string]any{node.outbound, {"type": "direct", "tag": "direct"}},
		"route":     route, "dns": dns,
	}
	data, err := json.Marshal(config)
	return string(data), err
}

func parseNodeLink(input string) (nodeLink, error) {
	raw := strings.TrimSpace(input)
	if len(raw) > maxNodeLink || strings.ContainsAny(raw, "\x00\r\n\t") {
		return nodeLink{}, errors.New("invalid_node_link")
	}
	scheme, payload, ok := strings.Cut(raw, "://")
	if !ok || payload == "" {
		return nodeLink{}, errors.New("invalid_node_link")
	}
	scheme = strings.ToLower(scheme)
	raw = scheme + "://" + payload
	if scheme == "vmess" && !strings.Contains(strings.SplitN(payload, "#", 2)[0], "@") {
		return parseVMessJSON(payload)
	}
	if scheme == "ss" && !strings.Contains(strings.SplitN(payload, "#", 2)[0], "@") {
		encoded, fragment, _ := strings.Cut(payload, "#")
		decoded, err := decodeNodeBase64(encoded)
		if err != nil {
			return nodeLink{}, err
		}
		credentials, address, ok := strings.Cut(string(decoded), "@")
		if !ok || strings.Contains(address, "@") {
			// Legacy links can have @ inside passwords, but never in the server address.
			at := strings.LastIndex(string(decoded), "@")
			if at < 0 {
				return nodeLink{}, errors.New("invalid_node_link")
			}
			credentials, address = string(decoded[:at]), string(decoded[at+1:])
		}
		method, password, ok := strings.Cut(credentials, ":")
		if !ok {
			return nodeLink{}, errors.New("invalid_node_credentials")
		}
		raw = "ss://" + url.UserPassword(method, password).String() + "@" + address
		if fragment != "" {
			raw += "#" + fragment
		}
	}
	var authorityPorts string
	if scheme == "hy2" || scheme == "hysteria2" {
		raw, authorityPorts = splitHysteriaAuthority(raw)
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || (u.Path != "" && u.Path != "/") || !validNodeHost(u.Hostname()) {
		return nodeLink{}, errors.New("invalid_node_address")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nodeLink{}, errors.New("invalid_node_options")
	}
	for _, values := range q {
		if len(values) != 1 {
			return nodeLink{}, errors.New("duplicate_node_option")
		}
	}
	if err := validateNodeVerification(q.Get); err != nil {
		return nodeLink{}, err
	}
	if authorityPorts != "" {
		if q.Has("mport") {
			return nodeLink{}, errors.New("duplicate_node_option")
		}
		q.Set("mport", authorityPorts)
	}
	kind := scheme
	if kind == "hy2" {
		kind = "hysteria2"
	}
	defaults := map[string]int{"hysteria2": 443, "trojan": 443, "tuic": 443, "socks5": 1080}
	port, err := nodePort(u.Port(), defaults[kind])
	if err != nil {
		return nodeLink{}, err
	}
	outbound := map[string]any{"type": kind, "tag": "node", "server": u.Hostname(), "server_port": port}
	node := nodeLink{name: nodeName(u.Fragment, u.Hostname()), kind: kind, outbound: outbound}
	user, password := "", ""
	hasPassword := false
	if u.User != nil {
		user = u.User.Username()
		password, hasPassword = u.User.Password()
	}
	switch kind {
	case "ss":
		node.kind = "shadowsocks"
		outbound["type"] = node.kind
		if !hasPassword {
			decoded, err := decodeNodeBase64(user)
			if err != nil {
				return nodeLink{}, errors.New("invalid_node_credentials")
			}
			user, password, hasPassword = strings.Cut(string(decoded), ":")
		}
		if user == "" || !hasPassword || password == "" {
			return nodeLink{}, errors.New("invalid_node_credentials")
		}
		outbound["method"], outbound["password"] = user, password
		if plugin := q.Get("plugin"); plugin != "" {
			name, options, _ := strings.Cut(plugin, ";")
			if name == "simple-obfs" || name == "obfs" {
				name = "obfs-local"
			}
			if name != "obfs-local" && name != "v2ray-plugin" {
				return nodeLink{}, errors.New("unsupported_shadowsocks_plugin")
			}
			outbound["plugin"], outbound["plugin_opts"] = name, options
		}
	case "vless", "vmess":
		if !validNodeUUID(user) || hasPassword {
			return nodeLink{}, errors.New("invalid_node_credentials")
		}
		outbound["uuid"] = user
		if kind == "vless" {
			if v := q.Get("encryption"); v != "" && v != "none" {
				return nodeLink{}, errors.New("unsupported_vless_encryption")
			}
			if v := q.Get("flow"); v != "" {
				if v != "xtls-rprx-vision" {
					return nodeLink{}, errors.New("unsupported_vless_flow")
				}
				outbound["flow"] = v
			}
		} else {
			security := q.Get("encryption")
			if security == "" {
				security = "auto"
			}
			if !validVMessSecurity(security) {
				return nodeLink{}, errors.New("unsupported_vmess_security")
			}
			outbound["security"] = security
		}
		if v := q.Get("packetEncoding"); v != "" {
			if v != "xudp" && v != "packetaddr" {
				return nodeLink{}, errors.New("unsupported_packet_encoding")
			}
			outbound["packet_encoding"] = v
		}
		if err := node.applyTransport(q); err != nil {
			return nodeLink{}, err
		}
		if err := node.applyTLS(q, q.Get("security")); err != nil {
			return nodeLink{}, err
		}
	case "trojan", "hysteria2":
		if user == "" && kind == "trojan" {
			return nodeLink{}, errors.New("invalid_node_credentials")
		}
		if hasPassword {
			user += ":" + password
		}
		outbound["password"] = user
		security := q.Get("security")
		if security == "" {
			security = "tls"
		}
		if kind == "hysteria2" && security != "tls" {
			return nodeLink{}, errors.New("unsupported_node_tls")
		}
		if err := node.applyTLS(q, security); err != nil {
			return nodeLink{}, err
		}
		if kind == "trojan" {
			if security == "none" {
				return nodeLink{}, errors.New("unsupported_node_tls")
			}
			if err := node.applyTransport(q); err != nil {
				return nodeLink{}, err
			}
		} else if err := node.applyHysteriaOptions(q); err != nil {
			return nodeLink{}, err
		}
	case "tuic":
		if !validNodeUUID(user) || !hasPassword || password == "" {
			return nodeLink{}, errors.New("invalid_node_credentials")
		}
		outbound["uuid"], outbound["password"] = user, password
		if err := node.applyTLS(q, "tls"); err != nil {
			return nodeLink{}, err
		}
		if cc := firstNodeOption(q, "congestion_control", "congestionControl"); cc != "" {
			if cc != "bbr" && cc != "cubic" && cc != "new_reno" {
				return nodeLink{}, errors.New("invalid_node_options")
			}
			outbound["congestion_control"] = cc
		}
		if mode := firstNodeOption(q, "udp_relay_mode", "udpRelayMode"); mode != "" {
			if mode != "native" && mode != "quic" {
				return nodeLink{}, errors.New("invalid_node_options")
			}
			outbound["udp_relay_mode"] = mode
		}
		if truthyNodeOption(q.Get("disable_sni")) {
			outbound["tls"].(map[string]any)["disable_sni"] = true
		}
	case "socks5":
		outbound["type"], outbound["version"] = "socks", "5"
		if user != "" {
			outbound["username"], outbound["password"] = user, password
		}
	default:
		return nodeLink{}, errors.New("unsupported_node_scheme")
	}
	return node, nil
}

// url.Parse expects a numeric authority port. Hysteria also permits ranges
// there, so isolate that field before parsing the rest as a standard URI.
func splitHysteriaAuthority(link string) (string, string) {
	scheme, tail, _ := strings.Cut(link, "://")
	end := strings.IndexAny(tail, "/?#")
	if end < 0 {
		end = len(tail)
	}
	authority := tail[:end]
	at := strings.LastIndexByte(authority, '@') + 1
	host, ports, err := net.SplitHostPort(authority[at:])
	if err != nil || !strings.ContainsAny(ports, ",-") {
		return link, ""
	}
	return scheme + "://" + authority[:at] + net.JoinHostPort(host, "443") + tail[end:], ports
}

func (n *nodeLink) applyHysteriaOptions(q url.Values) error {
	if obfs := q.Get("obfs"); obfs != "" {
		secret := q.Get("obfs-password")
		if obfs != "salamander" || secret == "" {
			return errors.New("unsupported_hysteria_obfuscation")
		}
		n.outbound["obfs"] = map[string]any{"type": obfs, "password": secret}
	}
	if ports := q.Get("mport"); ports != "" {
		ranges := []string{}
		for _, part := range strings.Split(ports, ",") {
			begin, end, _ := strings.Cut(strings.ReplaceAll(part, "-", ":"), ":")
			left, err := nodePort(begin, 0)
			if err != nil {
				return err
			}
			right, err := nodePort(end, left)
			if err != nil || left > right {
				return errors.New("invalid_node_port")
			}
			ranges = append(ranges, strconv.Itoa(left)+":"+strconv.Itoa(right))
		}
		n.outbound["server_ports"] = ranges
		delete(n.outbound, "server_port")
	}
	return nil
}

func validateNodeVerification(option func(string) string) error {
	if option("ech") != "" || option("echConfigList") != "" {
		return errors.New("unsupported_node_ech")
	}
	// The kernel can pin public keys. These link fields pin whole certificates.
	if option("pinSHA256") != "" || option("pcs") != "" || option("pinnedPeerCertSha256") != "" {
		return errors.New("unsupported_certificate_pin")
	}
	if option("vcn") != "" || option("verifyPeerCertByName") != "" {
		return errors.New("unsupported_certificate_names")
	}
	if option("pqv") != "" || option("mldsa65Verify") != "" {
		return errors.New("unsupported_reality_verification")
	}
	return nil
}

func (n *nodeLink) applyTLS(q url.Values, security string) error {
	if security == "" || security == "none" {
		if q.Get("pbk") != "" || q.Get("sid") != "" {
			return errors.New("unsupported_node_tls")
		}
		return nil
	}
	if security != "tls" && security != "reality" {
		return errors.New("unsupported_node_tls")
	}
	tls := map[string]any{"enabled": true}
	if name := firstNodeOption(q, "sni", "serverName", "peer"); name != "" {
		if !validNodeHost(name) {
			return errors.New("invalid_node_tls_name")
		}
		tls["server_name"] = name
	}
	if alpn := q.Get("alpn"); alpn != "" {
		tls["alpn"] = strings.Split(alpn, ",")
	}
	n.insecure = truthyNodeOption(firstNodeOption(q, "allowInsecure", "insecure", "skip-cert-verify"))
	if n.insecure {
		tls["insecure"] = true
	}
	fingerprint := q.Get("fp")
	if security == "reality" {
		public := q.Get("pbk")
		decoded, err := base64.RawURLEncoding.DecodeString(public)
		short := q.Get("sid")
		_, shortErr := hex.DecodeString(short)
		if err != nil || len(decoded) != 32 || shortErr != nil || len(short) > 16 || tls["server_name"] == nil {
			return errors.New("invalid_reality_options")
		}
		if n.insecure {
			return errors.New("unsupported_reality_insecure")
		}
		tls["reality"] = map[string]any{"enabled": true, "public_key": public, "short_id": short}
		if fingerprint == "" {
			fingerprint = "chrome"
		}
	}
	if fingerprint != "" && fingerprint != "none" {
		switch fingerprint {
		case "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized":
		default:
			return errors.New("unsupported_tls_fingerprint")
		}
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
	}
	n.outbound["tls"] = tls
	return nil
}

func (n *nodeLink) applyTransport(q url.Values) error {
	transport := firstNodeOption(q, "type", "net")
	path, host := q.Get("path"), q.Get("host")
	t := map[string]any{}
	switch transport {
	case "", "tcp", "raw":
		if header := q.Get("headerType"); header != "" && header != "none" {
			return errors.New("unsupported_node_transport")
		}
		return nil
	case "ws":
		t["type"] = "ws"
		if prefix, options, found := strings.Cut(path, "?ed="); found {
			early, err := strconv.Atoi(options)
			if err != nil || early < 0 || early > 65535 {
				return errors.New("invalid_node_options")
			}
			path = prefix
			if early > 0 {
				t["max_early_data"], t["early_data_header_name"] = early, "Sec-WebSocket-Protocol"
			}
		}
		if host != "" {
			t["headers"] = map[string]string{"Host": host}
		}
	case "grpc":
		if mode := q.Get("mode"); (mode != "" && mode != "gun") || q.Get("authority") != "" {
			return errors.New("unsupported_node_transport")
		}
		t["type"] = "grpc"
		t["service_name"] = strings.TrimPrefix(firstNodeOption(q, "serviceName", "service_name", "path"), "/")
		path = ""
	case "httpupgrade":
		t["type"] = "httpupgrade"
		if host != "" {
			t["host"] = host
		}
	case "h2", "http":
		t["type"] = "http"
		if host != "" {
			t["host"] = strings.Split(host, ",")
		}
	default:
		return errors.New("unsupported_node_transport")
	}
	if path != "" {
		t["path"] = path
	}
	n.outbound["transport"] = t
	return nil
}

func parseVMessJSON(payload string) (nodeLink, error) {
	encoded, fragment, _ := strings.Cut(payload, "#")
	decoded, err := decodeNodeBase64(encoded)
	if err != nil {
		return nodeLink{}, err
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(decoded, &fields) != nil {
		return nodeLink{}, errors.New("invalid_vmess_link")
	}
	value := func(name string) string {
		var s string
		if json.Unmarshal(fields[name], &s) == nil {
			return s
		}
		var number int
		if json.Unmarshal(fields[name], &number) == nil {
			return strconv.Itoa(number)
		}
		return ""
	}
	if err := validateNodeVerification(func(name string) string {
		var text string
		if raw, ok := fields[name]; ok && json.Unmarshal(raw, &text) != nil {
			// A security field with an unexpected type must not be treated as absent.
			return "invalid"
		}
		return text
	}); err != nil {
		return nodeLink{}, err
	}
	host, id := value("add"), value("id")
	port, err := nodePort(value("port"), 0)
	if err != nil || !validNodeHost(host) || !validNodeUUID(id) {
		return nodeLink{}, errors.New("invalid_vmess_link")
	}
	security := value("scy")
	if security == "" {
		security = "auto"
	}
	if !validVMessSecurity(security) {
		return nodeLink{}, errors.New("unsupported_vmess_security")
	}
	outbound := map[string]any{"type": "vmess", "tag": "node", "server": host, "server_port": port, "uuid": id, "security": security}
	if aid := value("aid"); aid != "" {
		count, err := strconv.Atoi(aid)
		if err != nil || count < 0 || count > 65535 {
			return nodeLink{}, errors.New("invalid_vmess_link")
		}
		outbound["alter_id"] = count
	}
	name := value("ps")
	if fragment != "" {
		if unescaped, err := url.PathUnescape(fragment); err == nil {
			name = unescaped
		}
	}
	n := nodeLink{kind: "vmess", name: nodeName(name, host), outbound: outbound}
	q := url.Values{"type": {value("net")}, "headerType": {value("type")}, "path": {value("path")}, "host": {value("host")},
		"sni": {value("sni")}, "alpn": {value("alpn")}, "fp": {value("fp")}, "allowInsecure": {value("allowInsecure")}}
	if err := n.applyTransport(q); err != nil {
		return nodeLink{}, err
	}
	if err := n.applyTLS(q, value("tls")); err != nil {
		return nodeLink{}, err
	}
	return n, nil
}

func decodeNodeBase64(raw string) ([]byte, error) {
	if decoded, err := url.PathUnescape(raw); err == nil {
		raw = decoded
	}
	raw = strings.TrimRight(raw, "=")
	for _, encoding := range []*base64.Encoding{base64.RawURLEncoding, base64.RawStdEncoding} {
		if data, err := encoding.DecodeString(raw); err == nil {
			return data, nil
		}
	}
	return nil, errors.New("invalid_node_encoding")
}

func validNodeHost(host string) bool {
	if net.ParseIP(host) != nil {
		return true
	}
	host = strings.TrimSuffix(host, ".")
	if host == "" || len(host) > 253 {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
				return false
			}
		}
	}
	return true
}

func nodePort(raw string, fallback int) (int, error) {
	if raw == "" && fallback > 0 {
		return fallback, nil
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port < 1 || port > 65535 {
		return 0, errors.New("invalid_node_port")
	}
	return port, nil
}

func validNodeUUID(id string) bool {
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	compact := strings.ReplaceAll(id, "-", "")
	_, err := hex.DecodeString(compact)
	return err == nil && len(compact) == 32
}

func validVMessSecurity(value string) bool {
	switch value {
	case "auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero":
		return true
	}
	return false
}

func nodeName(value, fallback string) string {
	name := strings.TrimSpace(strings.Map(func(ch rune) rune {
		if unicode.IsControl(ch) || unicode.In(ch, unicode.Cf) {
			return -1
		}
		return ch
	}, value))
	if name == "" {
		return fallback
	}
	r := []rune(name)
	return string(r[:min(80, len(r))])
}

func firstNodeOption(q url.Values, names ...string) string {
	for _, name := range names {
		if value := q.Get(name); value != "" {
			return value
		}
	}
	return ""
}

func truthyNodeOption(value string) bool {
	return value == "1" || strings.EqualFold(value, "true")
}
