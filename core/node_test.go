package aauvcore

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const testNodeUUID = "d7224bf2-660b-4f56-b9f9-2ede4eb82c6d"

func nodeFixtures() map[string]string {
	vmess := base64.RawStdEncoding.EncodeToString([]byte(`{"add":"node.example","port":443,"id":"` + testNodeUUID + `","aid":0,"net":"ws","path":"/chat","host":"edge.example","sni":"edge.example","tls":"tls","ps":"VMess test"}`))
	ss := base64.RawURLEncoding.EncodeToString([]byte("aes-128-gcm:synthetic:secret"))
	legacySS := base64.RawStdEncoding.EncodeToString([]byte("aes-128-gcm:synthetic@node.example:8388"))
	reality := base64.RawURLEncoding.EncodeToString(append([]byte{9}, make([]byte, 31)...))
	return map[string]string{
		"hysteria2-authority": "hy2://synthetic@[2001:db8::1]:443,4000-4500/?sni=edge.example",
		"ss":                  "ss://" + ss + "@node.example:8388#Test",
		"ss-legacy":           "ss://" + legacySS + "#Legacy",
		"vmess":               "vmess://" + vmess,
		"vmess-url":           "vmess://" + testNodeUUID + "@node.example:443?security=tls&type=httpupgrade&host=edge.example&path=%2Frelay",
		"vless":               "vless://" + testNodeUUID + "@node.example:443?security=reality&flow=xtls-rprx-vision&fp=chrome&sni=edge.example&pbk=" + reality + "&sid=0123456789abcdef",
		"trojan":              "trojan://synthetic%40secret@node.example:443?security=tls&type=grpc&serviceName=proxy&sni=edge.example",
		"hysteria2":           "hy2://tester:synthetic@node.example:443?obfs=salamander&obfs-password=synthetic&sni=edge.example&mport=1000-1100%2C1200",
		"tuic":                "tuic://" + testNodeUUID + ":synthetic@node.example:443?congestion_control=bbr&udp_relay_mode=native&sni=edge.example",
		"socks":               "socks5://test:synthetic@[2001:db8::1]:1080",
	}
}

func TestNodeConfigWithInstalledKernel(t *testing.T) {
	binary := os.Getenv("AAUV_SING_BOX_CHECK")
	for name, link := range nodeFixtures() {
		t.Run(name, func(t *testing.T) {
			metadata, err := InspectNodeLink(link)
			if err != nil || strings.Contains(metadata, "synthetic") || strings.Contains(metadata, testNodeUUID) {
				t.Fatal("could not produce credential-free node metadata", err)
			}
			for _, platform := range []string{"macos", "ios"} {
				config, err := BuildSingBoxNode(link, platform, 18924, false)
				if err != nil {
					t.Fatalf("%s configuration: %v", platform, err)
				}
				var parsed struct {
					Inbounds  []map[string]any `json:"inbounds"`
					Outbounds []map[string]any `json:"outbounds"`
					Route     map[string]any   `json:"route"`
				}
				if err = json.Unmarshal([]byte(config), &parsed); err != nil {
					t.Fatal(err)
				}
				if parsed.Route["final"] != "node" || len(parsed.Inbounds) != 1 || parsed.Outbounds[0]["tag"] != "node" {
					t.Fatal("proxy route not selected")
				}
				if platform == "macos" && (parsed.Inbounds[0]["listen"] != "127.0.0.1" || parsed.Inbounds[0]["type"] != "mixed") {
					t.Fatal("macOS listener is not loopback")
				}
				if platform == "ios" && parsed.Inbounds[0]["type"] != "tun" {
					t.Fatal("iOS tunnel is missing")
				}
				if binary != "" {
					file := filepath.Join(t.TempDir(), "proxy.json")
					if err = os.WriteFile(file, []byte(config), 0600); err != nil {
						t.Fatal(err)
					}
					if output, err := exec.Command(binary, "check", "-c", file).CombinedOutput(); err != nil {
						t.Fatalf("%s kernel check failed: %v %s", platform, err, output)
					}
				}
			}
		})
	}
}

func TestNodeSecurityOptions(t *testing.T) {
	insecure := "trojan://synthetic@node.example:443?allowInsecure=1"
	if _, err := BuildSingBoxNode(insecure, "macos", 18924, false); err == nil {
		t.Fatal("insecure node started without confirmation")
	}
	if config, err := BuildSingBoxNode(insecure, "macos", 18924, true); err != nil || !strings.Contains(config, `"insecure":true`) {
		t.Fatal("confirmed node settings changed", err)
	}
	for _, bad := range []string{
		"vless://" + testNodeUUID + "@node.example:443?type=xhttp",
		"vless://" + testNodeUUID + "@node.example:443?security=reality&sni=edge.example&pbk=bad",
		"trojan://synthetic@node.example:443?sni=a.example&sni=b.example",
		"ss://test@node.example:80",
		"hy2://synthetic@node.example:443?pinSHA256=synthetic",
		"socks5://node.example:65536",
		"https://example.invalid/subscription",
	} {
		if _, err := InspectNodeLink(bad); err == nil {
			t.Fatal("unsupported or invalid link accepted")
		}
	}
}

func TestUnsupportedNodeVerificationIsRejected(t *testing.T) {
	vless := "vless://" + testNodeUUID + "@node.example:443?security=tls"
	vmess := func(verification string) string {
		return "vmess://" + base64.RawStdEncoding.EncodeToString([]byte(
			`{"add":"node.example","port":443,"id":"`+testNodeUUID+`","tls":"tls",`+verification+`}`))
	}
	for _, tc := range []struct{ link, want string }{
		{vless + "&pcs=synthetic", "unsupported_certificate_pin"},
		{vless + "&vcn=other.example", "unsupported_certificate_names"},
		{nodeFixtures()["vless"] + "&pqv=synthetic", "unsupported_reality_verification"},
		{"trojan://synthetic@node.example?pinSHA256=pin&allowInsecure=1", "unsupported_certificate_pin"},
		{vmess(`"pinnedPeerCertSha256":["pin"]`), "unsupported_certificate_pin"},
		{vmess(`"echConfigList":"config"`), "unsupported_node_ech"},
	} {
		if _, err := InspectNodeLink(tc.link); err == nil || err.Error() != tc.want {
			t.Fatalf("inspection got %v, want %s", err, tc.want)
		}
		for _, platform := range []string{"macos", "ios"} {
			if _, err := BuildSingBoxNode(tc.link, platform, 18924, true); err == nil || err.Error() != tc.want {
				t.Fatalf("%s build got %v, want %s", platform, err, tc.want)
			}
		}
	}
	if _, err := InspectNodeLink(vless + "&pcs=&vcn=&pqv="); err != nil {
		t.Fatal("empty optional parameters changed link validity", err)
	}
}
